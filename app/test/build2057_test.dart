/// Build 2057 gates, host side: audit Batch 13 (Medium protocol
/// pack) + grouped Mediums/Lows where disjoint.
///
/// F-M10 the generic connect() routes WireGuard through the
/// peer-fallback path (an AWG attempt, or its diagnostics line,
/// on the home toggle) — F-M11 the Shadowsocks plugin is badged,
/// never silently dropped — F-M12 IPv6-literal share brackets —
/// F-M13 REALITY pqv end to end — F-M15 the fingerprint/pin
/// split — F-M2 the port validation matrix — §6 codec drops
/// (VMess mode/aid/scy/ech, TUIC ALPN, WG keepalive, QUIC
/// mapping, gRPC authority, anti-filter share params, http://
/// links, SOCKS password-only) — WG .conf AllowedIPs/DNS honesty
/// — B-M2 the stretched failover probe — B-M5 the doubling
/// reconnect backoff — Psiphon/Lantern tunnel DNS from Settings.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/reconnect_policy.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _read(String path) => File(path).readAsStringSync();
String _dart(String path) => _read('lib/$path');
String _kt(String name) =>
    _read('android/app/src/main/kotlin/com/ralysnd/ember/$name');

const _v6 = '2001:db8::1';

Profile _base(Protocol protocol) => Profile(
  id: 't1',
  protocol: protocol,
  name: 'Test',
  address: _v6,
  port: 8443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
);

void main() {
  group('F-M12 IPv6-literal share round-trip per protocol', () {
    test('vless/trojan/ss/hy2/wg/anytls/tuic/socks/http survive export→import',
        () {
      final cases = <Profile>[
        _base(Protocol.vless)..security = 'tls',
        _base(Protocol.trojan),
        _base(Protocol.shadowsocks)..method = 'aes-256-gcm',
        _base(Protocol.hysteria2),
        _base(Protocol.wireguard)
          ..secretKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
          ..peerPublicKey = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
        _base(Protocol.anytls),
        _base(Protocol.tuic),
        _base(Protocol.socks),
        _base(Protocol.http),
      ];
      for (final p in cases) {
        final link = profileToLink(p);
        // The authority must be bracketed — an unbracketed v6
        // address made the exported link unparseable.
        expect(
          link,
          contains('[$_v6]:8443'),
          reason: '${p.protocol} link: $link',
        );
        final back = parseLink(link);
        expect(back, isNotNull, reason: '${p.protocol} link: $link');
        expect(back!.address, _v6, reason: p.protocol.name);
        expect(back.port, 8443, reason: p.protocol.name);
      }
    });
  });

  group('F-M13 REALITY pqv end to end', () {
    const pqvLink =
        'vless://11111111-1111-1111-1111-111111111111@[2001:db8::1]:443'
        '?security=reality&sni=example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '&sid=abcd&fp=chrome&pqv=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB#PQ';
    test('parse → build emits mldsa65Verify → share → parse keeps pqv', () {
      final p = parseLink(pqvLink);
      expect(p, isNotNull);
      expect(p!.pqv, 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB');
      final out = buildOutbound(p, XraySettings());
      expect(out, isNotNull);
      final reality = (out!['streamSettings'] as Map)['realitySettings'] as Map;
      expect(
        reality['mldsa65Verify'],
        'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      );
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.pqv, p.pqv);
    });

    test('a profile without pqv emits no mldsa65Verify key', () {
      final p = _base(Protocol.vless)
        ..security = 'reality'
        ..publicKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      final out = buildOutbound(p, XraySettings());
      final reality = (out!['streamSettings'] as Map)['realitySettings'] as Map;
      expect(reality.containsKey('mldsa65Verify'), isFalse);
    });

    test('raw core JSON carrying mldsa65Verify keeps it', () {
      final parsed = parseSubscription(jsonEncode({
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'node.example.com',
                  'port': 443,
                  'users': [
                    {'id': '11111111-1111-1111-1111-111111111111'},
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'serverName': 'example.com',
                'fingerprint': 'chrome',
                'publicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
                'mldsa65Verify': 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
              },
            },
          },
        ],
      }));
      expect(parsed, hasLength(1));
      expect(
        parsed.first.pqv,
        'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
      );
    });
  });

  group('F-M15 fingerprint / pin split', () {
    const pin64 =
        'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
    test('a pin-shaped TLS fingerprint never reaches the core as a uTLS name',
        () {
      final p = _base(Protocol.vless)
        ..security = 'tls'
        ..fingerprint = pin64;
      final out = buildOutbound(p, XraySettings());
      final tls = (out!['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls.containsKey('fingerprint'), isFalse);
      expect(tls['pinnedPeerCertSha256'], pin64);
    });

    test('a pin-shaped REALITY fingerprint falls back to chrome', () {
      final p = _base(Protocol.vless)
        ..security = 'reality'
        ..fingerprint = pin64
        ..publicKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      final out = buildOutbound(p, XraySettings());
      final reality =
          (out!['streamSettings'] as Map)['realitySettings'] as Map;
      expect(reality['fingerprint'], 'chrome');
    });

    test('a real uTLS name still reaches the core unchanged', () {
      final p = _base(Protocol.vless)
        ..security = 'tls'
        ..fingerprint = 'chrome';
      final out = buildOutbound(p, XraySettings());
      final tls = (out!['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls['fingerprint'], 'chrome');
      expect(tls.containsKey('pinnedPeerCertSha256'), isFalse);
    });

    test('fingerprintPinFinding refuses a pin-shaped fingerprint', () {
      final p = _base(Protocol.vless)
        ..security = 'tls'
        ..fingerprint = pin64;
      expect(fingerprintPinFinding(p), contains('Certificate pin'));
      expect(
        fingerprintPinFinding(
          _base(Protocol.vless)..security = 'tls'..fingerprint = 'chrome',
        ),
        isNull,
      );
      // Hysteria2 is excluded: its pin lives in tlsCertPin and
      // the editor migrates a legacy fingerprint pin on open.
      expect(
        fingerprintPinFinding(
          _base(Protocol.hysteria2)..fingerprint = pin64,
        ),
        isNull,
      );
      // No security, no finding.
      expect(
        fingerprintPinFinding(_base(Protocol.vless)..fingerprint = pin64),
        isNull,
      );
    });
  });

  group('F-M2 port validation matrix', () {
    test('the default pair is valid', () {
      expect(
        validateXrayPorts(socksPort: 10808, httpPort: 10809),
        isNull,
      );
    });

    test('equal ports are refused with a named message', () {
      expect(
        validateXrayPorts(socksPort: 10808, httpPort: 10808),
        contains('different'),
      );
    });

    test('every reserved port is refused on either side', () {
      for (final reserved in [
        11808,
        11809,
        20810,
        20840,
        20841,
        20850,
        20851,
        20852,
        20853,
        20854,
        20870,
        11080,
        11170,
        11260,
      ]) {
        expect(
          validateXrayPorts(socksPort: reserved, httpPort: 10809),
          contains('$reserved'),
          reason: 'socks $reserved',
        );
        expect(
          validateXrayPorts(socksPort: 10808, httpPort: reserved),
          contains('$reserved'),
          reason: 'http $reserved',
        );
      }
    });

    test('the stats-port overflow is refused', () {
      expect(
        validateXrayPorts(socksPort: 60536, httpPort: 10809),
        contains('60535'),
      );
      expect(
        validateXrayPorts(socksPort: 60535, httpPort: 10809),
        isNull,
      );
    });

    test('the HTTP port must not be the stats port', () {
      expect(
        validateXrayPorts(socksPort: 10808, httpPort: 15808),
        contains('stats port'),
      );
    });

    test('out-of-range ports are refused', () {
      expect(
        validateXrayPorts(socksPort: 0, httpPort: 10809),
        contains('1 and 65535'),
      );
      expect(
        validateXrayPorts(socksPort: 10808, httpPort: 70000),
        contains('1 and 65535'),
      );
    });

    test('fromJson sanitises a stored colliding pair to the defaults', () {
      final s = XraySettings.fromJson({
        'socksPort': 11808,
        'httpPort': 10809,
      });
      expect(s.socksPort, 10808);
      expect(s.httpPort, 10809);
      final s2 = XraySettings.fromJson({
        'socksPort': 20000,
        'httpPort': 25001,
      });
      expect(s2.socksPort, 20000);
      expect(s2.httpPort, 25001);
    });

    test('statsApiPort never exceeds 65535, even for a rogue stored value',
        () {
      final s = XraySettings()..socksPort = 60535;
      expect(statsApiPort(s), 65535);
      final rogue = XraySettings()..socksPort = 70000;
      expect(statsApiPort(rogue), 15808);
    });
  });

  group('F-M11 Shadowsocks plugin badge', () {
    test('hasUnsupportedPlugin is true only with a plugin', () {
      expect(
        (_base(Protocol.shadowsocks)..plugin = 'obfs-local;obfs=http')
            .hasUnsupportedPlugin,
        isTrue,
      );
      expect(_base(Protocol.shadowsocks).hasUnsupportedPlugin, isFalse);
      expect(
        (_base(Protocol.vless)..plugin = 'obfs-local').hasUnsupportedPlugin,
        isFalse,
      );
    });

    test('the plugin round-trips through the share link', () {
      final p = _base(Protocol.shadowsocks)
        ..method = 'aes-256-gcm'
        ..plugin = 'obfs-local;obfs=http;obfs-host=example.com';
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.plugin, p.plugin);
      expect(back.hasUnsupportedPlugin, isTrue);
    });

    test('the home card badges a plugin profile (source pin)', () {
      expect(
        _dart('ui/ember/ember_home.dart'),
        contains('hasUnsupportedPlugin'),
      );
      expect(
        _dart('ui/ember/ember_home.dart'),
        contains('Plugin not applied'),
      );
    });
  });

  group('F-M10 generic connect routes WireGuard through the fallback path',
      () {
    test('connect() on an AWG profile attempts the AWG engine', () async {
      final c = XrayController();
      final p = Profile(
        id: 'wg1',
        protocol: Protocol.wireguard,
        name: 'AWG Node',
        address: '203.0.113.7',
        port: 51820,
        secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
        localAddress: '10.66.66.2/32',
        mtu: 1420,
        awgJc: '5',
        awgJmin: '50',
        awgJmax: '1000',
      );
      c.profiles = [p];
      c.select(p);
      // No device here: the AWG attempt fails on the missing
      // platform channel and the plain leg fails the same way,
      // so the connect throws — but the AWG attempt must have
      // happened first, which the diagnostics journal proves.
      await expectLater(c.connect(), throwsA(isA<StateError>()));
      expect(
        c.diagnostics.entries.any((e) => e.source == 'awg'),
        isTrue,
        reason: 'the generic path never attempted the AWG engine',
      );
    });
  });

  group('§6 codec drops', () {
    test('VMess mode/aid/scy/ech survive a share round-trip', () {
      final p = Profile(
        id: 'vm1',
        protocol: Protocol.vmess,
        name: 'VMess',
        address: 'node.example.com',
        port: 443,
        uuidOrPassword: '11111111-1111-1111-1111-111111111111',
        network: 'grpc',
        serviceName: 'gun-service',
        mode: 'multi',
        security: 'tls',
        aid: 64,
        scy: 'aes-128-gcm',
        echConfigList: 'example-ech-list',
      );
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.mode, 'multi');
      expect(back.aid, 64);
      expect(back.scy, 'aes-128-gcm');
      expect(back.echConfigList, 'example-ech-list');
      final out = buildOutbound(back, XraySettings());
      final users =
          (((out!['settings'] as Map)['vnext'] as List).first as Map)['users']
              as List;
      expect((users.first as Map)['alterId'], 64);
      expect((users.first as Map)['security'], 'aes-128-gcm');
    });

    test('VMess defaults still build exactly as before', () {
      final p = _base(Protocol.vmess);
      final out = buildOutbound(p, XraySettings());
      final users =
          (((out!['settings'] as Map)['vnext'] as List).first as Map)['users']
              as List;
      expect((users.first as Map)['alterId'], 0);
      expect((users.first as Map)['security'], 'auto');
    });

    test('TUIC ALPN survives a share round-trip', () {
      final p = _base(Protocol.tuic)..alpn = 'h3';
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.alpn, 'h3');
    });

    test('WireGuard keepalive survives a share round-trip', () {
      final p = _base(Protocol.wireguard)
        ..secretKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        ..peerPublicKey = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
        ..keepAlive = 25;
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.keepAlive, 25);
      final out = buildOutbound(back, XraySettings());
      final peers =
          ((out!['settings'] as Map)['peers'] as List).first as Map;
      expect(peers['keepAlive'], 25);
    });

    test('QUIC security/key come from the standard link parameters', () {
      final p = parseLink(
        'vless://11111111-1111-1111-1111-111111111111@node.example.com:443'
        '?type=quic&security=aes-128-gcm&key=secret-key&headerType=none#QUIC',
      );
      expect(p, isNotNull);
      expect(p!.network, 'quic');
      expect(p.security, isEmpty);
      final out = buildOutbound(p, XraySettings());
      final quic =
          (out!['streamSettings'] as Map)['quicSettings'] as Map;
      expect(quic['security'], 'aes-128-gcm');
      expect(quic['key'], 'secret-key');
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.host, 'aes-128-gcm');
      expect(back.path, 'secret-key');
    });

    test('gRPC authority survives a share round-trip and reaches the core',
        () {
      final p = _base(Protocol.vless)
        ..network = 'grpc'
        ..serviceName = 'svc'
        ..grpcAuthority = 'grpc.example.com'
        ..security = 'tls';
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.grpcAuthority, 'grpc.example.com');
      final out = buildOutbound(back, XraySettings());
      final grpc =
          (out!['streamSettings'] as Map)['grpcSettings'] as Map;
      expect(grpc['authority'], 'grpc.example.com');
    });

    test('anti-filter shaping survives a share round-trip', () {
      final p = _base(Protocol.vless)
        ..security = 'tls'
        ..afUnfilter = true
        ..afEch = true
        ..afFragment = 'tlshello-0len'
        ..afMixedSni = true
        ..afTcpNoise = true;
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.afUnfilter, isTrue);
      expect(back.afEch, isTrue);
      expect(back.afFragment, 'tlshello-0len');
      expect(back.afMixedSni, isTrue);
      expect(back.afTcpNoise, isTrue);
    });

    test('http:// proxy links parse, with and without credentials', () {
      final withCreds = parseLink('http://user:pass@proxy.example.com:8080#P');
      expect(withCreds, isNotNull);
      expect(withCreds!.protocol, Protocol.http);
      expect(withCreds.username, 'user');
      expect(withCreds.uuidOrPassword, 'pass');
      expect(profileToLink(withCreds), contains('http://user:pass@'));
      final bare = parseLink('http://proxy.example.com:8080#P');
      expect(bare, isNotNull);
      expect(bare!.protocol, Protocol.http);
      expect(bare.port, 8080);
      // A bare http(s) URL without a port is not a proxy link.
      expect(parseLink('http://example.com/something'), isNull);
      expect(parseLink('https://example.com/sub'), isNull);
      // The HTTP outbound builds.
      final out = buildOutbound(withCreds, XraySettings());
      expect(out!['protocol'], 'http');
    });

    test('SOCKS password-only export keeps the password', () {
      final p = _base(Protocol.socks)..uuidOrPassword = 'secret-pass';
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.uuidOrPassword, 'secret-pass');
      expect(back.username, isEmpty);
      final out = buildOutbound(back, XraySettings());
      final servers =
          ((out!['settings'] as Map)['servers'] as List).first as Map;
      expect((servers['users'] as List).first['pass'], 'secret-pass');
    });
  });

  group('WG .conf AllowedIPs/DNS honesty', () {
    test('AllowedIPs and DNS parse, and the builder applies the list', () {
      final r = parseWgConf(
        '[Interface]\n'
        'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        'Address = 10.66.66.2/32\n'
        'DNS = 10.64.0.1, 1.1.1.1\n'
        '[Peer]\n'
        'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n'
        'AllowedIPs = 10.0.0.0/8, 192.168.0.0/16\n'
        'Endpoint = 203.0.113.7:51820\n',
        baseName: 'Split',
        idFor: () => 'wg-split',
      );
      expect(r.ok, isTrue);
      expect(r.profiles, hasLength(1));
      final p = r.profiles.first;
      expect(p.wgAllowedIPs, '10.0.0.0/8,192.168.0.0/16');
      expect(p.wgDns, '10.64.0.1,1.1.1.1');
      final out = buildOutbound(p, XraySettings());
      final peers =
          ((out!['settings'] as Map)['peers'] as List).first as Map;
      expect(
        peers['allowedIPs'],
        ['10.0.0.0/8', '192.168.0.0/16'],
      );
      // The share link carries both, and they parse back.
      final back = parseLink(profileToLink(p));
      expect(back, isNotNull);
      expect(back!.wgAllowedIPs, p.wgAllowedIPs);
      expect(back.wgDns, p.wgDns);
    });

    test('a conf without MTU reads 1420, the link default', () {
      final r = parseWgConf(
        '[Interface]\n'
        'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        'Address = 10.66.66.2/32\n'
        '[Peer]\n'
        'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n'
        'Endpoint = 203.0.113.7:51820\n',
        baseName: 'NoMTU',
        idFor: () => 'wg-nomtu',
      );
      expect(r.profiles.first.mtu, 1420);
    });

    test('an explicit MTU is kept', () {
      final r = parseWgConf(
        '[Interface]\n'
        'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        'Address = 10.66.66.2/32\n'
        'MTU = 1280\n'
        '[Peer]\n'
        'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n'
        'Endpoint = 203.0.113.7:51820\n',
        baseName: 'MTU1280',
        idFor: () => 'wg-mtu',
      );
      expect(r.profiles.first.mtu, 1280);
    });
  });

  group('B-M2 failover probe stretch', () {
    test('base cadence, then 60 s after 3 idle successes, 120 s after 10',
        () {
      expect(
        adaptiveProbeEveryTicks(successStreak: 0, trafficActive: false),
        8,
      );
      expect(
        adaptiveProbeEveryTicks(successStreak: 2, trafficActive: false),
        8,
      );
      expect(
        adaptiveProbeEveryTicks(successStreak: 3, trafficActive: false),
        30,
      );
      expect(
        adaptiveProbeEveryTicks(successStreak: 9, trafficActive: false),
        30,
      );
      expect(
        adaptiveProbeEveryTicks(successStreak: 10, trafficActive: false),
        60,
      );
      // Any traffic resets to the base cadence, however long
      // the streak — failover latency on a used tunnel is
      // preserved.
      expect(
        adaptiveProbeEveryTicks(successStreak: 10, trafficActive: true),
        8,
      );
    });
  });

  group('B-M5 reconnect backoff', () {
    test('the wait doubles per attempt and caps at 80 s', () {
      expect(reconnectDelayForAttempt(baseSeconds: 10, attempt: 1), 10);
      expect(reconnectDelayForAttempt(baseSeconds: 10, attempt: 2), 20);
      expect(reconnectDelayForAttempt(baseSeconds: 10, attempt: 3), 40);
      expect(reconnectDelayForAttempt(baseSeconds: 10, attempt: 4), 80);
      expect(reconnectDelayForAttempt(baseSeconds: 10, attempt: 5), 80);
      expect(reconnectDelayForAttempt(baseSeconds: 5, attempt: 1), 5);
      expect(reconnectDelayForAttempt(baseSeconds: 5, attempt: 5), 80);
      expect(reconnectDelayForAttempt(baseSeconds: 60, attempt: 2), 80);
    });
  });

  group('§6 engine lows: Psiphon/Lantern tunnel DNS from Settings', () {
    test('Psiphon reads its DNS from the shell callback, not a constant',
        () {
      final dart = _dart('psiphon/psiphon_controller.dart');
      expect(dart, contains('String Function() localDns'));
      expect(dart, contains('dns: localDns(),'));
      expect(dart, isNot(contains("dns: '1.1.1.1',")));
      expect(
        _dart('ui/ember/ember_shell.dart'),
        contains('_psiphon.localDns = () => _xray.settings.localDns;'),
      );
    });

    test('Lantern threads the Settings DNS to the Builder (source pins)',
        () {
      expect(
        _dart('lantern/lantern_controller.dart'),
        contains('String Function() localDns'),
      );
      expect(
        _dart('lantern/lantern_platform.dart'),
        contains("'dns': dns,"),
      );
      expect(
        _dart('ui/ember/ember_shell.dart'),
        contains('_lantern.localDns = () => _xray.settings.localDns;'),
      );
      expect(_kt('MainActivity.kt'), contains('call.argument<String>("dns")'));
      expect(
        _kt('LanternVpnService.kt'),
        contains('putExtra(EXTRA_DNS, dns)'),
      );
      expect(
        _kt('LanternVpnService.kt'),
        contains('bridge.setSession(ipv6, mtu, dns)'),
      );
      // Build 2129: the Builder lives in the plugin-dex
      // bridge's openTun; the Settings DNS reaches it as the
      // session DNS (the core's own DNS request wins when it
      // names one — the gomobile shape; Ember's value is the
      // floor, never a hardcoded literal).
      final bridge = File(
        'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/LanternEngine.java',
      ).readAsStringSync();
      expect(bridge, contains('builder.addDnsServer('));
      expect(bridge, contains('this.dns'));
      expect(bridge, isNot(contains('addDnsServer("1.1.1.1")')));
    });
  });

  group('§7 comment-claims class: stale AWG comments corrected', () {
    test('no comment still claims the carrier cannot apply AWG params', () {
      expect(
        _dart('xray/link_parser.dart'),
        isNot(contains('the carrier cannot apply')),
      );
      expect(
        _dart('xray/wg_conf.dart'),
        isNot(contains('runs the profile as plain')),
      );
    });
  });
}
