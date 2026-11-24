// Build 2075 — the owner's 30 picked features: the sidecar
// engines (sing-box for TUIC v5 / Snell / NaiveProxy /
// Tailscale / OpenConnect, Mieru's own client, dnscrypt-proxy
// for DNSCrypt), smart dial racing + country exclusion on
// the fallback groups, the Psiphon bridge policy, the PIN
// app lock, the encrypted GitHub sync seal, Clash YAML
// import, the exit-IP quality parser, the config-builder
// additions (sidecar outbound, browser port, local proxy
// auth, DNS cache switch, multi-peer WireGuard), the Mirage
// finalmask preset, and the honest WireGuard peer liveness.
// Core-bound items parked with evidence live in the build
// log, not here — these pins cover what SHIPPED.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/net/exit_quality.dart';
import 'package:firefox_vpn/psiphon/psiphon_strategy.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/ui/ember/ember_sync.dart';
import 'package:firefox_vpn/ui/ember/wireguard_pages.dart';
import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/clash_import.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dnscrypt_config.dart';
import 'package:firefox_vpn/xray/exit_info.dart';
import 'package:firefox_vpn/xray/fallback_groups.dart';
import 'package:firefox_vpn/xray/mieru_config.dart';
import 'package:firefox_vpn/xray/sha256.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile prof(
  Protocol protocol, {
  String id = 'p1',
  String address = 'example.com',
  int port = 443,
  String cred = 'cred',
}) => Profile(
  id: id,
  protocol: protocol,
  address: address,
  port: port,
  uuidOrPassword: cred,
);

void main() {
  group('vendored sidecar binaries', () {
    test('sing-box is the official 1.14.4 android-arm64 build', () {
      final f = File('../../engines/singbox/sing-box');
      expect(f.existsSync(), isTrue);
      final bytes = f.readAsBytesSync();
      expect(bytes.length, 82765688);
      expect(
        sha256Hex(bytes),
        '2ce1c1c2a265e7be21ffa7aaf2b58619986629e9caecfc2d3f80ef4d25b7f965',
      );
      expect(bytes[18] | (bytes[19] << 8), 183); // EM_AARCH64
      expect(
        File('../../engines/singbox/PROVENANCE.md').readAsStringSync(),
        contains('2ce1c1c2'),
      );
    });

    test('mieru and dnscrypt-proxy are vendored with their hashes', () {
      final mieru = File('../../engines/mieru/mieru').readAsBytesSync();
      expect(mieru.length, 14549345);
      expect(
        sha256Hex(mieru),
        '5bac0b072958d481d16c5be2c13197ad071a44ac089e57f52c60dabad4613349',
      );
      final dns = File('../../engines/dnscrypt/dnscrypt-proxy')
          .readAsBytesSync();
      expect(dns.length, 13328928);
      expect(
        sha256Hex(dns),
        '25835fa3b123491a2c96d90148117f1c67889f4ee3dac6436db63750477336c9',
      );
    });

    test('the jniLibs copies are byte-identical and kept exact', () {
      const dir = 'android/app/src/main/jniLibs/arm64-v8a';
      expect(
        sha256Hex(File('$dir/libsingbox.so').readAsBytesSync()),
        '2ce1c1c2a265e7be21ffa7aaf2b58619986629e9caecfc2d3f80ef4d25b7f965',
      );
      expect(
        sha256Hex(File('$dir/libmieru.so').readAsBytesSync()),
        '5bac0b072958d481d16c5be2c13197ad071a44ac089e57f52c60dabad4613349',
      );
      expect(
        sha256Hex(File('$dir/libdnscrypt.so').readAsBytesSync()),
        '25835fa3b123491a2c96d90148117f1c67889f4ee3dac6436db63750477336c9',
      );
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('keepDebugSymbols += "**/libsingbox.so"'));
      expect(gradle, contains('keepDebugSymbols += "**/libmieru.so"'));
      expect(gradle, contains('keepDebugSymbols += "**/libdnscrypt.so"'));
    });

    test('the Kotlin sidecar cores and channel handlers exist', () {
      for (final name in ['SingBoxCore.kt', 'MieruCore.kt', 'DnsCryptCore.kt']) {
        expect(
          File('android/app/src/main/kotlin/com/ralysnd/ember/$name')
              .existsSync(),
          isTrue,
          reason: name,
        );
      }
      final kt = ktSrc('MainActivity.kt');
      for (final method in [
        'singboxStart',
        'singboxStop',
        'mieruStart',
        'dnscryptStart',
        'setOverlayGuard',
      ]) {
        expect(kt, contains('"$method"'), reason: method);
      }
      expect(kt, contains('notificationRotate'));
      expect(kt, contains('setHideOverlayWindows'));
    });

    test('the V2Ray notification carries a working Switch action', () {
      final svc = ktSrc('XrayVpnService.kt');
      expect(svc, contains('notification_rotate'));
      expect(svc, contains('ember_action'));
      final strings = File(
        'android/app/src/main/res/values/strings.xml',
      ).readAsStringSync();
      expect(strings, contains('Switch server'));
    });
  });

  group('protocol service truth table', () {
    test('the sidecar protocols are connectable, including AnyTLS', () {
      for (final p in [
        Protocol.tuic,
        // Build 2089 pin update: AnyTLS joined the sidecar —
        // sing-box 1.14.4's anytls outbound, verified by
        // `sing-box check` — so it is served and connectable
        // like the other 2075 protocols, while the Xray core
        // still has no outbound for it.
        Protocol.anytls,
        Protocol.snell,
        Protocol.naive,
        Protocol.tailscale,
        Protocol.openconnect,
      ]) {
        expect(p.servedBySingBox, isTrue, reason: p.label);
        expect(p.connectable, isTrue, reason: p.label);
        expect(p.supportedByCore, isFalse, reason: p.label);
      }
      expect(Protocol.mieru.servedByMieru, isTrue);
      expect(Protocol.mieru.connectable, isTrue);
      expect(Protocol.vless.supportedByCore, isTrue);
      expect(Protocol.vless.connectable, isTrue);
    });
  });

  group('sing-box config shapes', () {
    test('TUIC v5 carries uuid, password, congestion, relay mode', () {
      final p = prof(Protocol.tuic, cred: 'uuid-1')
        ..method = 'pw'
        ..sni = 'sni.example.com';
      final cfg = buildSingBoxConfig(p);
      final out = (cfg['outbounds'] as List).single as Map<String, dynamic>;
      expect(out['type'], 'tuic');
      expect(out['uuid'], 'uuid-1');
      expect(out['password'], 'pw');
      expect(out['congestion_control'], 'bbr');
      expect(out['udp_relay_mode'], 'native');
      expect((out['tls'] as Map)['server_name'], 'sni.example.com');
      expect((out['tls'] as Map)['alpn'], ['h3']);
      final inbound = (cfg['inbounds'] as List).single as Map<String, dynamic>;
      expect(inbound['type'], 'mixed');
      expect(inbound['listen_port'], singBoxListenPort);
      expect(singBoxConfigError(p), isNull);
      expect(
        singBoxConfigError(prof(Protocol.tuic, cred: '')),
        contains('no UUID'),
      );
    });

    test('Snell is version 4 with obfs passthrough', () {
      final p = prof(Protocol.snell, cred: 'psk')
        ..obfs = 'tls'
        ..obfsPassword = 'host.example.com';
      final out = (buildSingBoxConfig(p)['outbounds'] as List).single
          as Map<String, dynamic>;
      expect(out['type'], 'snell');
      expect(out['psk'], 'psk');
      expect(out['version'], 4);
      expect(out['obfs_mode'], 'tls');
      expect(out['obfs_host'], 'host.example.com');
    });

    test('Naive carries credentials; its TLS block only with an SNI', () {
      final plain = prof(Protocol.naive, cred: 'pw')..username = 'user';
      final out = (buildSingBoxConfig(plain)['outbounds'] as List).single
          as Map<String, dynamic>;
      expect(out['username'], 'user');
      expect(out['password'], 'pw');
      expect(out.containsKey('tls'), isFalse);
      final withSni = prof(Protocol.naive, cred: 'pw')
        ..sni = 'front.example.com';
      final out2 = (buildSingBoxConfig(withSni)['outbounds'] as List).single
          as Map<String, dynamic>;
      expect((out2['tls'] as Map)['server_name'], 'front.example.com');
    });

    test('Tailscale and OpenConnect are endpoints, port inside server', () {
      final ts = prof(Protocol.tailscale, address: '', cred: '')
        ..tailscaleAuthKey = 'tskey-abc';
      final cfgTs = buildSingBoxConfig(ts);
      expect(cfgTs.containsKey('outbounds'), isFalse);
      final ep = (cfgTs['endpoints'] as List).single as Map<String, dynamic>;
      expect(ep['type'], 'tailscale');
      expect(ep['auth_key'], 'tskey-abc');
      expect(singBoxConfigError(ts), isNull);
      expect(
        singBoxConfigError(prof(Protocol.tailscale, address: '', cred: '')),
        contains('auth key'),
      );

      final oc = prof(Protocol.openconnect, port: 4443, cred: 'pw')
        ..username = 'vpnuser';
      final epOc = (buildSingBoxConfig(oc)['endpoints'] as List).single
          as Map<String, dynamic>;
      expect(epOc['type'], 'openconnect');
      expect(epOc['server'], 'example.com:4443');
      expect(epOc['username'], 'vpnuser');
    });
  });

  group('mieru and dnscrypt configs', () {
    test('mieru config matches the validated client schema', () {
      final p = prof(Protocol.mieru, port: 7890, cred: 'pw')
        ..username = 'user'
        ..network = 'udp';
      final cfg = buildMieruConfig(p);
      expect(cfg['socks5Port'], mieruListenPort);
      expect(cfg['rpcPort'], mieruRpcPort);
      final profile = (cfg['profiles'] as List).single as Map<String, dynamic>;
      expect((profile['user'] as Map)['name'], 'user');
      expect((profile['user'] as Map)['password'], 'pw');
      final server = (profile['servers'] as List).single
          as Map<String, dynamic>;
      expect(server['domainName'], 'example.com');
      expect(
        ((server['portBindings'] as List).single as Map)['protocol'],
        'UDP',
      );
      // No mtu key: the model default is not a Mieru choice.
      expect(profile.containsKey('mtu'), isFalse);
      expect(mieruConfigError(p), isNull);
    });

    test('dnscrypt TOML pins the listener, servers and minisign key', () {
      final toml = buildDnsCryptConfig('/data/work');
      expect(toml, contains("listen_addresses = ['127.0.0.1:20530']"));
      expect(toml, contains("'cloudflare'"));
      expect(toml, contains('RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7G2'));
      expect(toml, contains('/data/work'));
    });
  });

  group('config builder additions', () {
    Profile vless() => prof(Protocol.vless, cred: 'uuid');

    test('the default config shape (2049 invariants, as amended '
        'by build 2101)', () {
      final cfg = decode(buildTunnelConfig(vless(), XraySettings()));
      final dns = cfg['dns'] as Map<String, dynamic>;
      expect(dns.containsKey('disableCache'), isFalse);
      // Build 2101 (owner order 2026-11-18): the built-in
      // fallback no longer rides the default shape. Build
      // 2113: the primary is the single Cloudflare DoH entry
      // (the 2111 UDP-first pair is gone) and nothing else
      // rides.
      expect((dns['servers'] as List).length, 1);
      final tags = [
        for (final i in cfg['inbounds'] as List) (i as Map)['tag'],
      ];
      expect(tags, isNot(contains('browser')));
      final socks = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      expect((socks['settings'] as Map).containsKey('accounts'), isFalse);
    });

    test('the DNS cache switch emits disableCache only when on', () {
      final s = XraySettings()..dnsCacheDisabled = true;
      final cfg = decode(buildTunnelConfig(vless(), s));
      expect((cfg['dns'] as Map)['disableCache'], isTrue);
    });

    test('a sidecar session points the proxy outbound at the sidecar', () {
      final cfg = decode(
        buildTunnelConfig(
          prof(Protocol.tuic, cred: 'uuid'),
          XraySettings(),
          sidecarSocksPort: singBoxListenPort,
        ),
      );
      final out = (cfg['outbounds'] as List).first as Map<String, dynamic>;
      expect(out['protocol'], 'socks');
      final server = ((out['settings'] as Map)['servers'] as List).single
          as Map<String, dynamic>;
      expect(server['address'], '127.0.0.1');
      expect(server['port'], singBoxListenPort);
      // The 2049 invariant stamped the IPv4-only dial strategy
      // here; build 2101 removes the whole pin family (owner
      // order 2026-11-18), so the sidecar outbound carries no
      // streamSettings at all now.
      expect(out['streamSettings'], isNull);
    });

    test('the browser port inbound appears only when enabled', () {
      final s = XraySettings()
        ..browserPortEnabled = true
        ..browserPort = 18080;
      final cfg = decode(buildTunnelConfig(vless(), s));
      final browser = (cfg['inbounds'] as List).firstWhere(
        (i) => (i as Map)['tag'] == 'browser',
      ) as Map<String, dynamic>;
      expect(browser['port'], 18080);
      expect(browser['protocol'], 'http');
      expect(browser['listen'], '127.0.0.1');
    });

    test('local proxy auth puts accounts on the loopback inbounds', () {
      final s = XraySettings()
        ..localProxyAuth = true
        ..localProxyUser = 'me'
        ..localProxyPass = 'secret';
      final cfg = decode(buildTunnelConfig(vless(), s));
      final socks = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      final settings = socks['settings'] as Map<String, dynamic>;
      expect(settings['auth'], 'password');
      final account = (settings['accounts'] as List).single
          as Map<String, dynamic>;
      expect(account['user'], 'me');
      expect(account['pass'], 'secret');
    });

    test('DNSCrypt as transport resolves through the local proxy', () {
      final s = XraySettings()..remoteDnsProto = 'dnscrypt';
      final cfg = decode(buildTunnelConfig(vless(), s));
      final dns = cfg['dns'] as Map<String, dynamic>;
      final servers = dns['servers'] as List;
      expect(servers.first, dnsCryptResolverAddress);
      // Build 2101: the built-in fallback no longer rides
      // along (removed by the owner's order) — the local proxy
      // stands alone.
      expect(servers.length, 1);
    });

    test('multi-peer WireGuard carries every peer of the group', () {
      final a = Profile(
        id: 'wg1',
        protocol: Protocol.wireguard,
        address: '1.2.3.4',
        port: 51820,
        secretKey: 'sk',
        peerPublicKey: 'pk1',
        localAddress: '10.0.0.2/32',
      );
      final b = Profile(
        id: 'wg2',
        protocol: Protocol.wireguard,
        address: '5.6.7.8',
        port: 51820,
        secretKey: 'sk',
        peerPublicKey: 'pk2',
        localAddress: '10.0.0.2/32',
      );
      final cfg = decode(
        buildTunnelConfig(a, XraySettings(), wgPeerProfiles: [a, b]),
      );
      final out = (cfg['outbounds'] as List).first as Map<String, dynamic>;
      final peers = (out['settings'] as Map)['peers'] as List;
      expect(peers.length, 2);
      expect((peers[1] as Map)['endpoint'], '5.6.7.8:51820');
    });
  });

  group('fallback groups: sidecars and country exclusion', () {
    test('a TUIC member and an AnyTLS member are eligible now', () {
      final current = prof(Protocol.vless, id: 'cur');
      final tuic = prof(Protocol.tuic, id: 'tuic');
      final anytls = prof(Protocol.anytls, id: 'any');
      final order = fallbackOrder(
        all: [current, tuic, anytls],
        current: current,
      );
      expect(order.map((p) => p.id), contains('tuic'));
      // Build 2089 pin update: AnyTLS is served by the
      // sing-box sidecar now, so it is an eligible fallback
      // member like TUIC — the old "still is not" is gone.
      expect(order.map((p) => p.id), contains('any'));
    });

    test('an excluded exit country is skipped, an unknown one is not', () {
      final current = prof(Protocol.vless, id: 'cur');
      final iranian = prof(Protocol.vless, id: 'ir')..exitCountryCode = 'IR';
      final unknown = prof(Protocol.vless, id: 'unk');
      final order = fallbackOrder(
        all: [current, iranian, unknown],
        current: current,
        excludedCountryCodes: {'IR'},
      );
      expect(order.map((p) => p.id), isNot(contains('ir')));
      expect(order.map((p) => p.id), contains('unk'));
    });
  });

  group('psiphon bridge policy', () {
    List<String> order(String mode) => psiphonRungOrder(
      method: '',
      lastWinner: '',
      hasEdges: true,
      hasPairing: true,
      hasUpstream: true,
      bridgeMode: mode,
    );

    test('auto keeps the full ladder', () {
      expect(order('auto'), psiphonAutoLadder);
    });

    test('bridges-only drops the direct rung D', () {
      expect(order('on'), isNot(contains('D')));
      expect(order('on'), contains('A'));
    });

    test('no-bridges drops the bridge rungs A and E', () {
      expect(order('off'), isNot(contains('A')));
      expect(order('off'), isNot(contains('E')));
      expect(order('off'), contains('D'));
    });
  });

  group('app lock', () {
    test('PIN rules and hashing', () {
      expect(isValidPin('1234'), isTrue);
      expect(isValidPin('123456'), isTrue);
      expect(isValidPin('123'), isFalse);
      expect(isValidPin('1234567'), isFalse);
      expect(isValidPin('12a4'), isFalse);
      expect(pinHashOf('1234'), isNot(pinHashOf('1235')));
      expect(pinHashOf('1234').length, 64);
    });
  });

  group('sync seal', () {
    test('a sealed backup round-trips; a wrong password opens nothing', () {
      const backup = '{"profiles":[],"settings":{}}';
      final sealed = sealBackup(backup, 'hunter2');
      expect(sealed, contains('ralysnd-ember-sync'));
      expect(sealed, isNot(contains('profiles')));
      expect(unsealBackup(sealed, 'hunter2'), backup);
      expect(unsealBackup(sealed, 'wrong'), isNull);
      expect(unsealBackup('{"app":"other"}', 'hunter2'), isNull);
      expect(unsealBackup('not json', 'hunter2'), isNull);
    });
  });

  group('clash YAML import', () {
    const doc = '''
proxies:
  - name: "SS One"
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: "secret"
  - name: "TUIC One"
    type: tuic
    server: tuic.example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    password: "pw"
    congestion-controller: bbr
  - name: "Snell One"
    type: snell
    server: snell.example.com
    port: 443
    psk: snellpsk
    version: 4
  - name: "Mystery"
    type: wireguard-go-plus
    server: x.example.com
    port: 1
''';

    test('a Clash document is recognised and parsed', () {
      expect(looksLikeClashYaml(doc), isTrue);
      expect(looksLikeClashYaml('vless://abc'), isFalse);
      var n = 0;
      final result = parseClashYaml(doc, () => 'id${n++}');
      final byName = {for (final p in result.profiles) p.name: p};
      expect(byName.keys, containsAll(['SS One', 'TUIC One', 'Snell One']));
      expect(byName['SS One']!.protocol, Protocol.shadowsocks);
      expect(byName['SS One']!.method, 'aes-256-gcm');
      expect(byName['TUIC One']!.protocol, Protocol.tuic);
      expect(byName['TUIC One']!.uuidOrPassword,
          '11111111-2222-3333-4444-555555555555');
      expect(byName['Snell One']!.protocol, Protocol.snell);
      expect(byName['Snell One']!.snellVersion, 4);
      expect(result.skipped, greaterThanOrEqualTo(1));
    });

    test('a malformed document yields nothing, never a throw', () {
      final result = parseClashYaml('proxies: [unclosed', () => 'x');
      expect(result.profiles, isEmpty);
    });
  });

  group('exit-IP quality', () {
    // Build 2095 (third-pass audit 5-7): the source is
    // ipwho.is over HTTPS now — the fixtures follow its
    // shape, and the flags verdict is honestly unknown.
    test('an ipwho.is answer parses with flags unknown', () {
      final q = parseExitQuality({
        'success': true,
        'ip': '8.8.8.8',
        'country': 'Netherlands',
        'country_code': 'NL',
        'city': 'Amsterdam',
        'connection': {'asn': 1234, 'org': 'Home ISP', 'isp': 'Home ISP'},
      });
      expect(q, isNotNull);
      expect(q!.ip, '8.8.8.8');
      expect(q.countryCode, 'NL');
      expect(q.isp, 'Home ISP');
      expect(q.asName, 'AS1234 Home ISP');
      expect(q.flagsKnown, isFalse);
      expect(q.label, 'Unrated');
    });

    test('flags-known verdicts keep the score math', () {
      const q = ExitQuality(
        ip: '1.2.3.4',
        hosting: true,
        proxy: true,
      );
      expect(q.score, 30);
      expect(q.label, 'Flagged');
      const clean = ExitQuality(ip: '8.8.8.8');
      expect(clean.score, 100);
      expect(clean.label, 'Clean');
    });

    test('a failed lookup parses to null', () {
      expect(parseExitQuality({'success': false}), isNull);
      expect(parseExitQuality(const {}), isNull);
    });
  });

  group('mirage finalmask preset', () {
    test('the preset is the tlshello fragment pass as JSON', () {
      final doc = jsonDecode(mirageFinalMaskJson) as Map<String, dynamic>;
      final tcp = (doc['tcp'] as List).single as Map<String, dynamic>;
      expect(tcp['type'], 'fragment');
      final settings = tcp['settings'] as Map<String, dynamic>;
      expect(settings['packets'], 'tlshello');
      expect(settings['lengths'], ['0', '104', '1']);
      // The same shape the anti-filter unfilter mask leads with.
      expect(afUnfilterFinalmask().first['type'], 'fragment');
      expect(
        (afUnfilterFinalmask().first['settings']
            as Map<String, dynamic>)['packets'],
        'tlshello',
      );
    });
  });

  group('wireguard peer honesty', () {
    XrayController controllerWith(XrayState state, {bool awg = false}) {
      final c = XrayController();
      c.state = state;
      c.awgSession = awg;
      addTearDown(c.dispose);
      return c;
    }

    XrayState running({int down = 0, int handshake = -1, bool awg = false}) =>
        XrayState(
          running: true,
          name: 'wg',
          sinceMs: 0,
          upBytes: 0,
          downBytes: down,
          awg: awg,
          awgHandshakeAgeSec: handshake,
        );

    test('a running tunnel with no answer is NOT proven', () {
      final c = controllerWith(running());
      final live = wgPeerLiveness(c);
      expect(live.proven, isFalse);
      expect(live.line, contains('not answered'));
    });

    test('traffic flow proves a plain peer', () {
      final c = controllerWith(running(down: 1200));
      expect(wgPeerLiveness(c).proven, isTrue);
    });

    test('a verified exit proves a plain peer', () {
      final c = controllerWith(running());
      c.exitInfo = const ExitInfo(
        ip: '1.2.3.4',
        countryCode: 'NL',
        countryEn: 'Netherlands',
      );
      expect(wgPeerLiveness(c).proven, isTrue);
    });

    test('an AWG peer needs its handshake', () {
      final silent = controllerWith(running(awg: true), awg: true);
      expect(wgPeerLiveness(silent).proven, isFalse);
      final shaken = controllerWith(
        running(awg: true, handshake: 12),
        awg: true,
      );
      final live = wgPeerLiveness(shaken);
      expect(live.proven, isTrue);
      expect(live.line, contains('Handshake'));
    });
  });

  group('settings wiring pins', () {
    test('the reconnect policy rows predate 2075 and stay (item 15)', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, contains('Reconnect delay'));
      expect(settings, contains('Reconnect attempts'));
      expect(settings, contains("'Smart dial racing'"));
      expect(settings, contains("'Excluded exit countries'"));
      expect(settings, contains("'Routing by network type'"));
      expect(settings, contains("'Dedicated browser port'"));
      expect(settings, contains("'Require a login on this device'"));
      expect(settings, contains("'Use all peers of a WireGuard config'"));
      expect(settings, contains("title: 'Privacy & sync'"));
    });

    test('the DNS section carries DNSCrypt and the cache switch', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, contains('DNSCrypt'));
      expect(settings, contains('Disable DNS cache'));
    });

    test('the shell gates on the app lock and rotates from notifications', () {
      final shell = dartSrc('ui/ember/ember_shell.dart');
      expect(shell, contains('AppLockPage'));
      expect(shell, contains('appLockEnabled'));
      expect(shell, contains('applyRoutingForNetwork'));
    });

    test('the editor carries the sidecar protocol sections', () {
      final editor = dartSrc('ui/ember/profile_editor.dart');
      expect(editor, contains('Snell (via sing-box)'));
      expect(editor, contains('Tailscale (via sing-box)'));
      // Build 2079: the 'Mirage mask' paste chip was replaced
      // by the first-class 'mirage' fragment shape — the editor
      // now carries the TLS fragmentation dropdown (build2079
      // pins the Mirage option in it), not the chip.
      expect(editor, contains('TLS fragmentation'));
      expect(editor, contains('sing-box engine'));
    });
  });
}
