/// Build 2095, fourth-pass audit — hostile-input pins.
///
/// - 4.1/2.1/2.2/2.3/2.4/4.2: the import-boundary
///   validation module repairs out-of-range numerics,
///   unknown enums and impossible combinations at every
///   entry route.
/// - 1.4: AWG values cannot inject UAPI lines.
/// - 1.5: names lose control characters.
/// - 1.1: the fetcher body is byte-capped (loopback
///   server) and one paste cannot import past the
///   profile cap.
/// - 1.2: a YAML alias bomb bails instead of expanding.
/// - 1.3: document parsers degrade per entry.
/// - 3.1/3.2/3.3: Clash field restorations.
/// - 3.6: ss/socks userinfo is base64URL.
/// - 3.7: JSON wireguard/hysteria outbounds import.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/clash_import.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/profile_validation.dart';
import 'package:firefox_vpn/xray/sub_fetcher.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _p({
  Protocol protocol = Protocol.vless,
  int port = 443,
  String network = 'tcp',
  String security = 'tls',
}) => Profile(
  id: 'x',
  protocol: protocol,
  name: 'n',
  address: 'h.example.com',
  port: port,
  uuidOrPassword: 'u',
  network: network,
  security: security,
);

void main() {
  group('validation module (audit 4.1/2.1/2.2/2.3/4.2)', () {
    test('numerics are repaired to the core ranges', () {
      final p = _p(port: 99999);
      p.mtu = 0;
      p.snellVersion = 9;
      p.aid = -5;
      p.upMbps = 99999999999;
      p.downMbps = -3;
      sanitizeImportedProfile(p);
      expect(p.port, 443);
      expect(p.mtu, 1420);
      expect(p.snellVersion, 4);
      expect(p.aid, 0);
      expect(p.upMbps, 100000);
      expect(p.downMbps, 0);
      expect(sanitizeImportedProfile(_p(port: -1)).port, 443);
    });

    test('enum strings are whitelisted', () {
      final p = _p(network: 'banana', security: 'weird');
      sanitizeImportedProfile(p);
      expect(p.network, 'tcp');
      // Build 2096 pin change (post-2095 audit L26): an
      // unknown security value used to be reset to '' —
      // plaintext. It now fails closed to 'tls'.
      expect(p.security, 'tls');
      final tuic = _p(protocol: Protocol.tuic)
        ..congestionControl = 'xyz'
        ..udpRelayMode = 'bogus';
      sanitizeImportedProfile(tuic);
      expect(tuic.congestionControl, '');
      expect(tuic.udpRelayMode, '');
      final xh = _p(network: 'xhttp')..mode = 'novel-mode';
      sanitizeImportedProfile(xh);
      expect(xh.mode, 'auto');
    });

    test('vision flow survives only where the core loads it', () {
      final ws = _p(network: 'ws')..flow = 'xtls-rprx-vision';
      sanitizeImportedProfile(ws);
      expect(ws.flow, '');
      final tcp = _p()..flow = 'xtls-rprx-vision';
      sanitizeImportedProfile(tcp);
      expect(tcp.flow, 'xtls-rprx-vision');
      final noSec = _p(security: '')..flow = 'xtls-rprx-vision';
      sanitizeImportedProfile(noSec);
      expect(noSec.flow, '');
    });

    test('REALITY over QUIC is coerced to TLS', () {
      // Build 2096 pin change (post-2095 audit M1): the
      // coercion moved from the import boundary (which
      // silently rewrote the stored profile) to emit
      // time — the profile keeps 'reality', the built
      // stream settings carry TLS.
      final p = _p(network: 'quic', security: 'reality');
      sanitizeImportedProfile(p);
      expect(p.security, 'reality');
      expect(p.hasRealityTransportMismatch, isTrue);
      final out = buildOutbound(p, XraySettings())!;
      final stream = out['streamSettings'] as Map;
      expect(stream['security'], 'tls');
      expect(stream.containsKey('tlsSettings'), isTrue);
      expect(stream.containsKey('realitySettings'), isFalse);
    });

    test('reserved survives only as exactly three bytes', () {
      final ok = _p(protocol: Protocol.wireguard)..reserved = '1,2,3';
      sanitizeImportedProfile(ok);
      expect(ok.reserved, '1,2,3');
      final short = _p(protocol: Protocol.wireguard)..reserved = '1,2';
      sanitizeImportedProfile(short);
      expect(short.reserved, '');
      final big = _p(protocol: Protocol.wireguard)..reserved = '1,2,300';
      sanitizeImportedProfile(big);
      expect(big.reserved, '');
    });

    test('hostile links are repaired at the parse boundary', () {
      final bad = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@h.example.com:99999'
        '?type=banana&security=tls#N',
      )!;
      expect(bad.port, 443);
      expect(bad.network, 'tcp');
      final flow = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@h.example.com:443'
        '?type=ws&security=tls&flow=xtls-rprx-vision#N',
      )!;
      expect(flow.flow, '');
    });
  });

  group('AWG line injection (audit 1.4)', () {
    test('a newline-bearing jc value cannot inject hand-off lines', () {
      final p = parseLink(
        'wireguard://aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU%3D'
        '@wg.example.com:51820'
        '?publickey=aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU%3D'
        '&jc=5%0Aallowed_ip%3D0.0.0.0%2F0&allowedips=10.0.0.0%2F8#W',
      )!;
      expect(p.awgJc.contains('\n'), isFalse);
      expect(RegExp(r'^\d*$').hasMatch(p.awgJc), isTrue);
      // Build 2104: the injection surface is the .conf
      // hand-off text now (the UAPI string is deleted with
      // the old bridge); the property is unchanged — the
      // sanitized jc cannot smuggle an extra route line,
      // and the only AllowedIPs line is the profile's own.
      final conf = wgConfFromProfile(p);
      final allowedLines = conf
          .split('\n')
          .where((l) => l.startsWith('AllowedIPs'))
          .toList();
      expect(allowedLines, ['AllowedIPs = 10.0.0.0/8']);
    });

    test('names lose control characters (audit 1.5)', () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@h.example.com:443'
        '?security=tls#evil%0Aname%E2%80%AEspoof',
      )!;
      expect(p.name.contains('\n'), isFalse);
      expect(p.name.contains('\u202E'), isFalse);
      expect(sanitizeProfileName('a\rb\u2066c'), 'a b c');
    });
  });

  group('size and count bounds (audit 1.1)', () {
    test('a paste past the profile cap counts the excess as skipped', () {
      final link =
          'vless://11111111-1111-1111-1111-111111111111@h.example.com:443'
          '?security=tls#N';
      final text = List.filled(kMaxImportedProfiles + 25, link).join('\n');
      final r = parseLinksDetailed(text);
      expect(r.profiles, hasLength(kMaxImportedProfiles));
      expect(r.skipped, hasLength(25));
    });

    test('the fetcher refuses an oversized body', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.add(List.filled(17 * 1024 * 1024, 65));
        request.response.close();
      });
      Object? error;
      try {
        await fetchSubscription(
          'http://127.0.0.1:${server.port}/sub',
          responseTimeout: const Duration(seconds: 10),
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<SubFetchException>());
      expect((error! as SubFetchException).message, contains('too large'));
    });
  });

  group('Clash robustness + restorations (audit 1.2/1.3/3.1/3.2/3.3)', () {
    test('an alias bomb bails to an empty import, fast', () {
      final lvl = StringBuffer('a0: &a0 [1,2,3,4,5,6,7,8,9,10]\n');
      for (var i = 1; i <= 6; i++) {
        lvl.write('a$i: &a$i [');
        lvl.write(List.filled(10, '*a${i - 1}').join(','));
        lvl.write(']\n');
      }
      final doc =
          '''
$lvl
proxies:
  - name: bomb
    type: ss
    server: h.example.com
    port: 8388
    cipher: aes-256-gcm
    password: pw
    alpn: *a6
''';
      final r = parseClashYaml(doc, () => 'id1');
      expect(r.profiles, isEmpty);
    });

    test('an absurd bandwidth digit run no longer empties the import', () {
      const doc = '''
proxies:
  - name: hy
    type: hysteria2
    server: h.example.com
    port: 443
    password: pw
    up: "99999999999999999999999 Mbps"
    ports: "20000-30000"
''';
      final r = parseClashYaml(doc, () => 'id1');
      expect(r.profiles, hasLength(1));
      expect(r.profiles.single.upMbps, 100000);
      expect(r.profiles.single.hyMport, '20000-30000');
      // Build 2116 (audit B2-2) deliberate re-point: the
      // hopping this build 2095 fixture proved was CARRIED
      // is now APPLIED — an mport profile is served by the
      // sing-box sidecar — so it is no longer "ignored";
      // the import assertions above are unchanged.
      expect(r.profiles.single.hasIgnoredPortHopping, isFalse);
      expect(r.profiles.single.hy2SidecarServed, isTrue);
    });

    test('WG allowed-ips/dns, fingerprint, reality-opts, h2-opts land', () {
      const doc = '''
proxies:
  - name: wg
    type: wireguard
    server: wg.example.com
    port: 51820
    private-key: aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=
    public-key: aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=
    ip: 10.0.0.2
    allowed-ips: ["10.0.0.0/8", "192.168.0.0/16"]
    dns: 1.1.1.1
  - name: vm
    type: vmess
    server: v.example.com
    port: 443
    uuid: 11111111-1111-1111-1111-111111111111
    alterId: 0
    cipher: auto
    tls: true
    client-fingerprint: chrome
    network: h2
    h2-opts:
      path: /secret
      host: [cdn.example.com]
  - name: tj
    type: trojan
    server: t.example.com
    port: 443
    password: pw
    reality-opts:
      public-key: PUBKEY
      short-id: abcd
''';
      final r = parseClashYaml(doc, () => 'id${DateTime.now().microsecond}');
      expect(r.profiles, hasLength(3));
      final wg = r.profiles.firstWhere((p) => p.name == 'wg');
      expect(wg.wgAllowedIPs, '10.0.0.0/8,192.168.0.0/16');
      expect(wg.wgDns, '1.1.1.1');
      final vm = r.profiles.firstWhere((p) => p.name == 'vm');
      expect(vm.fingerprint, 'chrome');
      expect(vm.path, '/secret');
      expect(vm.host, 'cdn.example.com');
      final tj = r.profiles.firstWhere((p) => p.name == 'tj');
      expect(tj.security, 'reality');
      expect(tj.publicKey, 'PUBKEY');
      expect(tj.shortId, 'abcd');
    });
  });

  group('JSON document robustness (audit 1.3/3.7)', () {
    test('per-entry degradation: string port imports, poisoned entry skips',
        () {
      final doc = jsonEncode([
        {
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'a.example.com',
                    'port': '443',
                    'users': [
                      {'id': '11111111-1111-1111-1111-111111111111'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'tls'},
            },
          ],
        },
        {
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': ['not-a-map'],
              'streamSettings': {},
            },
          ],
        },
        {
          'outbounds': [
            {
              'protocol': 'wireguard',
              'settings': {
                'secretKey': 'aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=',
                'address': ['10.0.0.2/32'],
                'peers': [
                  {
                    'publicKey':
                        'aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGU=',
                    'endpoint': 'wg.example.com:51820',
                    'allowedIPs': ['10.0.0.0/8'],
                  },
                ],
              },
              'streamSettings': {},
            },
          ],
        },
        {
          'outbounds': [
            {
              'protocol': 'hysteria',
              'settings': {'address': 'hy.example.com', 'port': 443},
              'streamSettings': {
                'hysteriaSettings': {'auth': 'secret'},
              },
            },
          ],
        },
      ]);
      final profiles = parseSubscription(doc);
      expect(profiles, hasLength(3));
      expect(
        profiles.any((p) => p.protocol == Protocol.wireguard),
        isTrue,
      );
      expect(
        profiles.any((p) => p.protocol == Protocol.hysteria2),
        isTrue,
      );
      final wg = profiles.firstWhere(
        (p) => p.protocol == Protocol.wireguard,
      );
      expect(wg.address, 'wg.example.com');
      expect(wg.wgAllowedIPs, '10.0.0.0/8');
    });
  });

  group('interop (audit 3.5/3.6)', () {
    test('ss and socks exports use base64URL userinfo', () {
      final ss = Profile(
        id: 's1',
        protocol: Protocol.shadowsocks,
        name: 'ss',
        address: 'h.example.com',
        port: 8388,
        method: 'aes-256-gcm',
        uuidOrPassword: 'p>>>???\u00fb\u00ff',
      );
      final link = profileToLink(ss);
      final cred = link.substring(5, link.indexOf('@'));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(cred), isTrue);
      final back = parseLink(link)!;
      expect(back.uuidOrPassword, ss.uuidOrPassword);
      expect(back.method, 'aes-256-gcm');

      final socks = Profile(
        id: 's2',
        protocol: Protocol.socks,
        name: 'sk',
        address: 'h.example.com',
        port: 1080,
        username: 'user>>>',
        uuidOrPassword: 'pass???',
      );
      final slink = profileToLink(socks);
      final scred = slink.substring(8, slink.indexOf('@'));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(scred), isTrue);
      final sback = parseLink(slink)!;
      expect(sback.username, 'user>>>');
      expect(sback.uuidOrPassword, 'pass???');
    });

    test('a non-salamander Hy2 obfs is flagged, salamander is not', () {
      // Build 2116 (audit B2-7) deliberate re-point: gecko
      // is APPLIED now (the sing-box sidecar serves the
      // profile), so the flagged fixture becomes an obfs
      // type no engine applies; the salamander half is
      // unchanged, and gecko's new truth is asserted too.
      final gecko = parseLink(
        'hysteria2://pw@h.example.com:443?obfs=gecko&obfs-password=x#N',
      )!;
      expect(gecko.hasUnappliedObfs, isFalse);
      expect(gecko.hy2SidecarServed, isTrue);
      final unknown = parseLink(
        'hysteria2://pw@h.example.com:443?obfs=quic&obfs-password=x#N',
      )!;
      expect(unknown.hasUnappliedObfs, isTrue);
      final sal = parseLink(
        'hysteria2://pw@h.example.com:443?obfs=salamander&obfs-password=x#N',
      )!;
      expect(sal.hasUnappliedObfs, isFalse);
    });

    test('a stored hostile document is repaired by fromJson', () {
      final p = Profile.fromJson({
        'id': 'z',
        'name': 'evil\nname',
        'protocol': 'vless',
        'address': 'h.example.com',
        'port': 99999,
        'network': 'banana',
        'security': 'tls',
        'uuidOrPassword': 'u',
      });
      expect(p.port, 443);
      expect(p.network, 'tcp');
      expect(p.name.contains('\n'), isFalse);
    });
  });
}
