/// Build 2041 gates, host side: Custom DNS Hosts entries — the
/// user's own domain-to-IP map, answered by the tunnel's DNS
/// before any resolver is asked (LxBox v2.25.19-rc.1 suggestion,
/// 2026-11-12). Verified honest in the bundled Xray-core
/// v26.10.29 source before building: the core's DNS config
/// takes a `hosts` map (infra/conf/dns.go HostsWrapper /
/// HostAddress — one address string or a list per name), and
/// the app already emits one for the built-in resolver pins
/// (_dnsHostPins), so user entries ride the same mechanism with
/// no core change. These tests pin the DART side of that
/// contract: validation, parsing, storage, and the emitted
/// config — including the no-regression case that a store with
/// no custom hosts emits exactly the old pins.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dns_hosts.dart';
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

Map<String, dynamic> dnsHostsOf(XraySettings s) {
  final cfg = decode(buildTunnelConfig(_vless(), s));
  return (cfg['dns'] as Map<String, dynamic>)['hosts']
      as Map<String, dynamic>;
}

void main() {
  group('Custom DNS hosts (build 2041)', () {
    test('domain validation accepts plain and local names', () {
      expect(dnsHostDomainValid('example.com'), isTrue);
      expect(dnsHostDomainValid('sub.example.co.uk'), isTrue);
      expect(dnsHostDomainValid('wg.home'), isTrue);
      expect(dnsHostDomainValid('nas'), isTrue);
      expect(dnsHostDomainValid('a-b.example.com'), isTrue);
      expect(dnsHostDomainValid('xn--nxasmq6b.example'), isTrue);
    });

    test('domain validation rejects bad names', () {
      expect(dnsHostDomainValid(''), isFalse);
      expect(dnsHostDomainValid('.example.com'), isFalse);
      expect(dnsHostDomainValid('example.com.'), isFalse);
      expect(dnsHostDomainValid('ex ample.com'), isFalse);
      expect(dnsHostDomainValid('under_score.com'), isFalse);
      expect(dnsHostDomainValid('-bad.com'), isFalse);
      expect(dnsHostDomainValid('bad-.com'), isFalse);
      expect(dnsHostDomainValid('a..b.com'), isFalse);
      expect(dnsHostDomainValid('*.example.com'), isFalse);
      expect(dnsHostDomainValid('1.2.3.4'), isFalse);
      expect(dnsHostDomainValid('::1'), isFalse);
      expect(dnsHostDomainValid('${'a' * 64}.com'), isFalse);
      expect(dnsHostDomainValid('${'a' * 250}.com'), isFalse);
    });

    test('IP validation accepts v4 and v6, rejects the rest', () {
      expect(dnsHostIpValid('1.2.3.4'), isTrue);
      expect(dnsHostIpValid('8.8.8.8'), isTrue);
      expect(dnsHostIpValid('0.0.0.0'), isTrue);
      expect(dnsHostIpValid('::1'), isTrue);
      expect(dnsHostIpValid('2001:db8::1'), isTrue);
      expect(dnsHostIpValid('fe80::1'), isTrue);
      expect(dnsHostIpValid('999.1.1.1'), isFalse);
      expect(dnsHostIpValid('1.2.3'), isFalse);
      expect(dnsHostIpValid('1.2.3.4.5'), isFalse);
      expect(dnsHostIpValid('abc'), isFalse);
      expect(dnsHostIpValid(''), isFalse);
      expect(dnsHostIpValid('fe80::1%eth0'), isFalse);
      expect(dnsHostIpValid('1.2.3.4/32'), isFalse);
      expect(dnsHostIpValid('example.com'), isFalse);
    });

    test('parseDnsHostsText: valid lines, blanks, case, duplicates', () {
      final parsed = parseDnsHostsText(
        'example.com = 1.2.3.4\n'
        '\n'
        '  SUB.Example.ORG=8.8.4.4  \n'
        'wg.home = 10.0.0.5\n'
        'example.com = 9.9.9.9\n',
      );
      expect(parsed.invalidLines, isEmpty);
      expect(parsed.entries, {
        'example.com': '9.9.9.9', // last duplicate wins
        'sub.example.org': '8.8.4.4', // keys lower-cased
        'wg.home': '10.0.0.5',
      });
    });

    test('parseDnsHostsText names the bad lines', () {
      final parsed = parseDnsHostsText(
        'good.example = 1.2.3.4\n'
        'bad domain = 1.2.3.4\n'
        'alsobad.example = not-an-ip\n'
        'no-equals-here\n'
        'example.com =\n',
      );
      expect(parsed.entries, {'good.example': '1.2.3.4'});
      expect(parsed.invalidLines, [
        'bad domain = 1.2.3.4',
        'alsobad.example = not-an-ip',
        'no-equals-here',
        'example.com =',
      ]);
    });

    test('dnsHostsText round-trips through the parser', () {
      const hosts = {
        'example.com': '1.2.3.4',
        'wg.home': '10.0.0.5',
        'sub.example.org': '2001:db8::1',
      };
      expect(parseDnsHostsText(dnsHostsText(hosts)).entries, hosts);
      expect(parseDnsHostsText(dnsHostsText(hosts)).invalidLines, isEmpty);
    });

    test('validDnsHosts drops invalid pairs, lower-cases keys', () {
      expect(
        validDnsHosts({
          'Good.Example': '1.2.3.4',
          'bad domain': '1.2.3.4',
          'alsobad.example': 'nope',
        }),
        {'good.example': '1.2.3.4'},
      );
    });

    test('settings round-trip keeps hosts; old stores load empty', () {
      final s = XraySettings()..customDnsHosts = {
        'example.com': '1.2.3.4',
        'wg.home': '10.0.0.5',
      };
      final back = XraySettings.fromJson(s.toJson());
      expect(back.customDnsHosts, s.customDnsHosts);
      expect(XraySettings.fromJson({}).customDnsHosts, isEmpty);
    });

    test('fromJson drops invalid stored entries, never throws', () {
      final s = XraySettings.fromJson({
        'customDnsHosts': {
          'good.example': '1.2.3.4',
          'bad domain': '1.2.3.4',
          'alsobad.example': 'not-an-ip',
          'UPPER.EXAMPLE': '8.8.8.8',
          'num': 42,
        },
      });
      expect(s.customDnsHosts, {
        'good.example': '1.2.3.4',
        'upper.example': '8.8.8.8',
      });
      // A corrupt store of any type reads as empty, not a crash.
      expect(
        XraySettings.fromJson({'customDnsHosts': 'junk'}).customDnsHosts,
        isEmpty,
      );
      expect(
        XraySettings.fromJson({'customDnsHosts': [1, 2]}).customDnsHosts,
        isEmpty,
      );
    });

    test('builder emits a user entry as a plain string', () {
      // Build 2113: upstream emits user hosts as plain strings
      // (its PREF_DNS_HOSTS values are single addresses); the
      // pre-2113 one-element-list form is gone.
      final s = XraySettings()
        ..customDnsHosts = {'my.provider.example': '203.0.113.7'};
      final hosts = dnsHostsOf(s);
      expect(hosts['my.provider.example'], '203.0.113.7');
    });

    test('builder: a user entry wins over a built-in pin', () {
      final s = XraySettings()..customDnsHosts = {'dns.google': '8.8.4.4'};
      final hosts = dnsHostsOf(s);
      expect(hosts['dns.google'], '8.8.4.4');
      // The other pins are untouched.
      expect(hosts['dns.quad9.net'], [
        '9.9.9.9',
        '149.112.112.112',
        '2620:fe::fe',
        '2620:fe::9',
      ]);
    });

    test('builder: no custom hosts emits exactly the upstream pins', () {
      // Build 2113: the built-in table is upstream v2rayNG's
      // 15 entries, verbatim (the pre-2113 8-entry subset,
      // including doh.dns.sb and dns.adguard-dns.com, is
      // gone).
      final hosts = dnsHostsOf(XraySettings());
      expect(hosts.length, 15);
      expect(hosts, {
        'domain:googleapis.cn': 'googleapis.com',
        'dns.alidns.com': ['223.5.5.5', '223.6.6.6', '2400:3200::1', '2400:3200:baba::1'],
        'dns.sse.cisco.com': ['208.67.220.220', '208.67.222.222', '2620:119:35::35', '2620:119:53::53'],
        'dns.umbrella.com': ['208.67.220.220', '208.67.222.222', '2620:119:35::35', '2620:119:53::53'],
        'one.one.one.one': ['1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'],
        '1dot1dot1dot1.cloudflare-dns.com': ['1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'],
        'dns.cloudflare.com': ['162.159.61.8', '172.64.41.8', '2a06:98c1:52::8', '2803:f800:53::8'],
        'cloudflare-dns.com': ['104.16.248.249', '104.16.249.249', '2606:4700::6810:f8f9', '2606:4700::6810:f9f9'],
        'engage.cloudflareclient.com': ['162.159.192.1', '2606:4700:d0::a29f:c001'],
        'doh.pub': ['1.12.12.12', '120.53.53.53'],
        'dot.pub': ['1.12.12.12', '120.53.53.53'],
        'dns.google': ['8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'],
        'dns.quad9.net': ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'],
        'dns.sb': ['45.11.45.11', '185.222.222.222', '2a09::', '2a11::'],
        'common.dot.dns.yandex.net': ['77.88.8.8', '77.88.8.1', '2a02:6b8::feed:0ff', '2a02:6b8:0:1::feed:0ff'],
      });
    });

    test('builder: invalid stored entries never reach the config', () {
      final s = XraySettings.fromJson({
        'customDnsHosts': {
          'good.example': '1.2.3.4',
          'bad domain': '1.2.3.4',
          'alsobad.example': 'not-an-ip',
        },
      });
      final hosts = dnsHostsOf(s);
      expect(hosts['good.example'], '1.2.3.4');
      expect(hosts.containsKey('bad domain'), isFalse);
      expect(hosts.containsKey('alsobad.example'), isFalse);
    });

    test('TCP-mode resolver IPs stay the built-in pins', () {
      // Deliberate: tcpFormOf maps a DoH hostname to its pinned
      // IP — a literal tcp:// IP needs no resolution, so a user
      // hosts entry must not move it. The 2037 contract holds.
      // Build 2101: the default remote is Cloudflare's DoH now,
      // so the live pin under test is 1.1.1.1 (the provider
      // mappings themselves are unchanged — Google's DoH still
      // maps to its own pin when a user picks it).
      final s = XraySettings()
        ..remoteDnsProto = 'tcp'
        ..customDnsHosts = {'cloudflare-dns.com': '203.0.113.7'};
      expect(tcpFormOf('https://dns.google/dns-query'), 'tcp://8.8.8.8');
      expect(
        tcpFormOf('https://cloudflare-dns.com/dns-query'),
        'tcp://1.1.1.1',
      );
      expect(dnsServersOfTcp(s), contains('tcp://1.1.1.1'));
      expect(dnsServersOfTcp(s), isNot(contains('tcp://203.0.113.7')));
    });
  });
}

List<dynamic> dnsServersOfTcp(XraySettings s) {
  final cfg = decode(buildTunnelConfig(_vless(), s));
  return (cfg['dns'] as Map<String, dynamic>)['servers'] as List;
}
