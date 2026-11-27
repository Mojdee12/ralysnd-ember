/// Build 2032 gates, host side: the WireGuard .conf parser
/// (one profile per peer, peer groups, AmneziaWG honesty), the
/// store-wide identity dedupe key, the DoQ resolver mapping,
/// and the Aether options round-trip. The engines themselves
/// are native/device-side; their evidence is the packaging
/// gates and the owner's device test.

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_platform.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

int _seq = 0;
String _id() => 't${_seq++}';

const _confSingle = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.8.0.2/32
DNS = 1.1.1.1
MTU = 1400

[Peer]
PublicKey = HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
''';

const _confMulti = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.8.0.2/32, fd01::2/128

[Peer]
PublicKey = HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = [2001:db8::1]:51821
AllowedIPs = 0.0.0.0/0
''';

const _confAmnezia = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.8.0.2/32
Jc = 5
Jmin = 40
Jmax = 70
S1 = 90
S2 = 110
H1 = 1234567890
H2 = 2345678901
H3 = 3456789012
H4 = 4567890123

[Peer]
PublicKey = HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

void main() {
  group('wg conf parser', () {
    test('single peer parses into one profile', () {
      final r = parseWgConf(_confSingle, baseName: 'Home', idFor: _id);
      expect(r.ok, isTrue);
      expect(r.amnezia, isFalse);
      final p = r.profiles.single;
      expect(p.protocol, Protocol.wireguard);
      expect(p.address, 'engage.cloudflareclient.com');
      expect(p.port, 2408);
      expect(p.keepAlive, 25);
      expect(p.mtu, 1400);
      expect(p.localAddress, '10.8.0.2/32');
      expect(p.name, 'Home');
    });

    test('multiple peers become a fallback group', () {
      final r = parseWgConf(_confMulti, baseName: 'Office', idFor: _id);
      expect(r.ok, isTrue);
      expect(r.profiles, hasLength(2));
      expect(r.profiles[0].name, 'Office · 1/2');
      expect(r.profiles[1].name, 'Office · 2/2');
      expect(r.profiles[1].address, '2001:db8::1');
      expect(r.profiles[1].port, 51821);
      // One group: same interface keys and addresses.
      expect(wgGroupKey(r.profiles[0]), wgGroupKey(r.profiles[1]));
      // …but different identities (the peer key differs).
      expect(
        profileIdentityKey(r.profiles[0]),
        isNot(profileIdentityKey(r.profiles[1])),
      );
    });

    test('amnezia parameters are flagged, not dropped silently', () {
      final r = parseWgConf(_confAmnezia, baseName: 'AWG', idFor: _id);
      expect(r.ok, isTrue);
      expect(r.amnezia, isTrue);
    });

    test('a conf without a private key fails loudly', () {
      final r = parseWgConf(
        '[Interface]\nAddress = 10.0.0.2/32\n\n[Peer]\n'
        'PublicKey = x\nEndpoint = 1.2.3.4:51820\n',
        baseName: 'Bad',
        idFor: _id,
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('PrivateKey'));
    });
  });

  group('identity dedupe key', () {
    Profile vless(String name, String uuid, int port) => Profile(
      id: _id(),
      name: name,
      protocol: Protocol.vless,
      address: 'Example.COM',
      port: port,
      uuidOrPassword: uuid,
    );

    test('the name is not identity; credentials and endpoint are', () {
      final a = vless('First name', 'uuid-1', 443);
      final b = vless('A different name', 'uuid-1', 443);
      expect(profileIdentityKey(a), profileIdentityKey(b));
      final c = vless('First name', 'uuid-1', 8443);
      expect(profileIdentityKey(a), isNot(profileIdentityKey(c)));
      final d = vless('First name', 'uuid-2', 443);
      expect(profileIdentityKey(a), isNot(profileIdentityKey(d)));
    });
  });

  group('dns transports', () {
    test('doq mapping covers the well-known providers', () {
      expect(
        doqFormOf('https://dns.google/dns-query'),
        'quic+local://dns.google',
      );
      expect(
        doqFormOf('https://cloudflare-dns.com/dns-query'),
        'quic+local://one.one.one.one',
      );
      expect(
        doqFormOf('https://dns.quad9.net/dns-query'),
        'quic+local://dns.quad9.net',
      );
      expect(
        doqFormOf('https://dns.example.org/dns-query'),
        'quic+local://dns.example.org',
      );
    });

    test('primaryResolver honours the transport choice', () {
      // Build 2113: the shipped default remote is v2rayNG's
      // Cloudflare DoH again (the 2111 plain-IP default is
      // reverted); the transport mapping itself is unchanged.
      final s = XraySettings();
      expect(primaryResolver(s), 'https://cloudflare-dns.com/dns-query');
      s.remoteDns = 'https://cloudflare-dns.com/dns-query';
      s.remoteDnsProto = 'doq';
      expect(primaryResolver(s), 'quic+local://one.one.one.one');
      s.adBlockDoh = true;
      expect(primaryResolver(s), 'quic+local://dns.adguard-dns.com');
    });
  });

  group('aether options', () {
    test('json round-trip and peer pinning', () {
      const o = AetherOptions(
        protocol: 'gool',
        scan: 'stealth',
        transport: 'h2',
        fragment: true,
        keepalive: 60,
        peer: '203.0.113.5:500',
      );
      final back = AetherOptions.fromJson(o.toJson());
      expect(back.protocol, 'gool');
      expect(back.scan, 'stealth');
      expect(back.transport, 'h2');
      expect(back.fragment, isTrue);
      expect(back.keepalive, 60);
      expect(back.peer, '203.0.113.5:500');
      expect(o.copyWith(clearPeer: true).peer, isNull);
      final m = o.toMap('masque');
      expect(m['engine'], 'masque');
      expect(m['peer'], '203.0.113.5:500');
    });
  });
}
