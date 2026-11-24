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
      // Build 2113: upstream's table carries no
      // dns.adguard-dns.com pin, so the host form is used.
      expect(
        tcpFormOf('https://dns.adguard-dns.com/dns-query'),
        'tcp://dns.adguard-dns.com',
      );
      expect(
        tcpFormOf('https://dns.alidns.com/dns-query'),
        'tcp://223.5.5.5',
      );
      // Build 2113: upstream's table carries no doh.dns.sb
      // pin either (dns.sb is pinned, doh.dns.sb is not), so
      // the host form is used.
      expect(
        tcpFormOf('https://doh.dns.sb/dns-query'),
        'tcp://doh.dns.sb',
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
      // Build 2113: no AdGuard pin in upstream's table, so
      // the TCP form is the host form.
      expect(primaryResolver(ad), 'tcp://dns.adguard-dns.com');
    });

    test('primaryResolver: an unknown stored proto falls back to DoH', () {
      // The fallback-to-DoH behavior is unchanged; the test
      // runs on the explicit Cloudflare DoH value (build
      // 2111's shipped default is plain 1.1.1.1, which passes
      // through the same unmapped path).
      final s = XraySettings()
        ..remoteDns = 'https://cloudflare-dns.com/dns-query'
        ..remoteDnsProto = 'tls';
      expect(primaryResolver(s), 'https://cloudflare-dns.com/dns-query');
      s.remoteDnsProto = 'doh';
      expect(primaryResolver(s), 'https://cloudflare-dns.com/dns-query');
      s.remoteDnsProto = 'doq';
      expect(primaryResolver(s), 'quic+local://one.one.one.one');
    });

    test('DNS section in TCP mode: tcp:// primary, pins kept', () {
      final servers = dnsServersOf(_tcp());
      // Build 2049's built-in fallback (Quad9 over TCP behind
      // the primary) is REMOVED in build 2101 by the owner's
      // order — the primary stands alone now.
      expect(servers, ['tcp://8.8.8.8']);
      final cfg = decode(buildTunnelConfig(_vless(), _tcp()));
      final dns = cfg['dns'] as Map<String, dynamic>;
      // Build 2103 (diagnosis D2/E2): the DNS section's tag
      // is v2rayNG's own 'dns-module' now, pinned to the
      // proxy by an explicit routing rule.
      expect(dns['tag'], 'dns-module');
      expect(
        (dns['hosts'] as Map<String, dynamic>)['dns.google'],
        ['8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'],
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
      // Build 2101: no built-in fallback follows anymore
      // (removed by the owner's order; see build2101_test.dart).
      expect(dnsServersOf(s), ['fakedns', 'tcp://8.8.8.8']);
    });

    test('settings: the TCP choice round-trips; old JSON defaults to DoH', () {
      final s = XraySettings()..remoteDnsProto = 'tcp';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.remoteDnsProto, 'tcp');
      // Build 2101: the default remote is Cloudflare now, so
      // its TCP form is the 1.1.1.1 pin.
      expect(primaryResolver(back), 'tcp://1.1.1.1');
      final old = XraySettings.fromJson({'remoteDns': 'https://dns.google/dns-query'});
      expect(old.remoteDnsProto, 'doh');
    });

    test('DoH/DoQ regression: nothing changes when TCP is not chosen', () {
      // Build 2049 amended this shape with its built-in TCP
      // fallback; build 2101 (owner order 2026-11-18) removes
      // the fallback AND moves the default remote to
      // v2rayNG's Cloudflare DoH. Build 2111 moved the
      // default to plain 1.1.1.1 with the DoH appended;
      // build 2113 removes the append and restores the
      // Cloudflare DoH default, so the section carries the
      // single stored entry; under DoQ it maps to the one
      // quic+local form, so DoQ mode stays pure DoQ.
      expect(dnsServersOf(XraySettings()), [
        'https://cloudflare-dns.com/dns-query',
      ]);
      final doq = XraySettings()..remoteDnsProto = 'doq';
      expect(dnsServersOf(doq), [
        'quic+local://one.one.one.one',
      ]);
      final doqGroup = XraySettings()
        ..remoteDnsProto = 'doq'
        ..dnsGroup = true;
      expect(dnsServersOf(doqGroup), [
        'quic+local://one.one.one.one',
        'quic+local://dns.google',
        'quic+local://dns.quad9.net',
      ]);
    });
  });
}
