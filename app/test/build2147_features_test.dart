// Build 2147 — the Iran feature set's host-side pins.
//
// What is pinned here: the pure module (iran_features_2147),
// the config shapes (FinalMask #7/#8, Balancer #5, SSH #6),
// the settings/profile persistence of every new field, the
// default-subscription constants (#21b), and the OFF
// defaults of every new gate. Nothing here claims a device
// behaviour — the walks, probes and handshakes are the
// owner's phone's verdicts.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/iran_features_2147.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile _vless({String network = 'tcp', String id = 'v1'}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: 'v',
  address: 'nl1.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: network,
  security: 'tls',
  sni: 'nl1.example.net',
);

void main() {
  group('build 2147 — gates default OFF, persistence', () {
    test('every new XraySettings gate defaults off/empty', () {
      final s = XraySettings();
      expect(s.fetchViaTunnel, isFalse);
      expect(s.autoMtu, isFalse);
      expect(s.autoMtuFound, 0);
      expect(s.dpiLabRacing, isFalse);
      expect(s.sniScanEnabled, isFalse);
      expect(s.balancerGroupIds, isEmpty);
      expect(s.sidecarSshEnabled, isFalse);
      expect(s.stallFailover, isFalse);
      expect(s.stallFailoverSeconds, 30);
      expect(s.exitMonitorEnabled, isFalse);
      expect(s.scheduledTests, isFalse);
      expect(s.scheduledTestIntervalMin, 60);
      expect(s.importSafetyFilter, isFalse);
      expect(s.quarantineEnabled, isFalse);
      expect(s.pingSweepEnabled, isFalse);
      expect(s.pingSweepFailStrikes, 3);
      expect(s.defaultSubsSeeded2147, isFalse);
      expect(s.sweepMissByProfile, isEmpty);
    });

    test('the new settings survive a json round trip', () {
      final s = XraySettings()
        ..fetchViaTunnel = true
        ..balancerGroupIds = ['g1', 'g2']
        ..sweepMissByProfile = {'p1': 2}
        ..autoMtuFound = 1380;
      final back = XraySettings.fromJson(s.toJson());
      expect(back.fetchViaTunnel, isTrue);
      expect(back.balancerGroupIds, ['g1', 'g2']);
      expect(back.sweepMissByProfile, {'p1': 2});
      expect(back.autoMtuFound, 1380);
    });

    test('the new profile fields survive a json round trip', () {
      final p = _vless()
        ..sshUser = 'root'
        ..xdnsDomain = 't.example.net'
        ..xicmpEnabled = true
        ..wgFallbackEndpoints = '1.2.3.4:51820'
        ..quarantineStrikes = 2
        ..quarantineNetwork = 'fp1';
      final back = Profile.fromJson(p.toJson());
      expect(back.sshUser, 'root');
      expect(back.xdnsDomain, 't.example.net');
      expect(back.xicmpEnabled, isTrue);
      expect(back.wgFallbackEndpoints, '1.2.3.4:51820');
      expect(back.quarantineStrikes, 2);
      expect(back.quarantineNetwork, 'fp1');
      expect(back.quarantined, isFalse);
    });
  });

  group('build 2147 — #21b default subscriptions', () {
    test('both slots, verbatim URLs', () {
      expect(kDefaultSubscriptions2147, hasLength(2));
      expect(kDefaultSubscriptions2147[0].name, 'Default source 1');
      expect(
        kDefaultSubscriptions2147[0].url,
        'https://sub.darkpx.workers.dev/all',
      );
      expect(kDefaultSubscriptions2147[1].name, 'Default source 2');
      expect(
        kDefaultSubscriptions2147[1].url,
        'https://www.ermao.net/sub/v2ray/ermao.net',
      );
    });
  });

  group('build 2147 — #18 import safety (pure)', () {
    test('anytls is SUPPORTED (sidecar since 2089); v1 hysteria is not', () {
      expect(isUnsupportedSchemeLink('anytls://pw@h:443#x'), isFalse);
      expect(isUnsupportedSchemeLink('vless://u@h:443#x'), isFalse);
      expect(isUnsupportedSchemeLink('ssh://root@h:22#x'), isFalse);
      expect(isUnsupportedSchemeLink('hysteria://h:443#x'), isTrue);
      expect(isUnsupportedSchemeLink('juicity://h:443#x'), isTrue);
      expect(isUnsupportedSchemeLink('not a link'), isFalse);
    });

    test('unsupportedSchemesInBody scans plain and base64 bodies', () {
      const plain = 'vless://u@h:443#a\nhysteria://h:443#b\n';
      expect(unsupportedSchemesInBody(plain), ['hysteria']);
      final b64 = base64.encode(utf8.encode(plain));
      expect(unsupportedSchemesInBody(b64), ['hysteria']);
      expect(unsupportedSchemesInBody('vless://u@h:443#a'), isEmpty);
    });

    test('local endpoints and tracker payloads warn; public ones do not', () {
      final local = _vless()..address = '127.0.0.1';
      expect(importSafetyWarnings(local), isNotEmpty);
      expect(importSafetyWarnings(_vless()), isEmpty);
      expect(
        linkPayloadWarnings('vless://u@h:443?hwid=ABC#x'),
        isNotEmpty,
      );
      expect(linkPayloadWarnings('vless://u@h:443#x'), isEmpty);
    });
  });

  group('build 2147 — #2/#20/#21a pure logic', () {
    test('the MTU walk picks the largest answering size', () {
      expect(pickMtuFromWalk([true]), 1500);
      expect(pickMtuFromWalk([false, true]), 1472);
      expect(pickMtuFromWalk([false, false, false, false, true]), 1280);
      expect(pickMtuFromWalk([false, false]), isNull);
      expect(pickMtuFromWalk([]), isNull);
    });

    test('quarantine strikes count per network', () {
      final p = _vless();
      var r = nextQuarantineStrikes(p, 'net-a');
      expect(r.strikes, 1);
      p.quarantineStrikes = r.strikes;
      p.quarantineNetwork = r.network;
      r = nextQuarantineStrikes(p, 'net-a');
      expect(r.strikes, 2);
      // A failure on a NEW network restarts the count.
      r = nextQuarantineStrikes(p, 'net-b');
      expect(r.strikes, 1);
      expect(r.network, 'net-b');
    });

    test('the sweep cut threshold', () {
      expect(
        sweepShouldCut(consecutiveMisses: 2, threshold: 3),
        isFalse,
      );
      expect(sweepShouldCut(consecutiveMisses: 3, threshold: 3), isTrue);
      // A threshold below 1 clamps to 1 (the module's rule).
      expect(sweepShouldCut(consecutiveMisses: 5, threshold: 0), isTrue);
      expect(sweepShouldCut(consecutiveMisses: 0, threshold: 3), isFalse);
    });

    test('WG fallback endpoints parse and copy', () {
      final p = _vless()
        ..wgFallbackEndpoints = ' 1.2.3.4:51820, bad, 5.6.7.8:51821 ';
      expect(parseWgFallbackEndpoints(p.wgFallbackEndpoints), [
        (host: '1.2.3.4', port: 51820),
        (host: '5.6.7.8', port: 51821),
      ]);
      final candidates = wgConnectCandidates(p);
      expect(candidates, hasLength(3));
      expect(candidates[1].address, '1.2.3.4');
      expect(candidates[1].id, p.id);
      expect(p.address, 'nl1.example.net');
    });
  });

  group('build 2147 — #7/#8 typed FinalMask', () {
    test('a kcp profile with an xdns domain emits the typed mask', () {
      final p = _vless(network: 'kcp')..xdnsDomain = 't.example.net';
      final config = _decode(buildTunnelConfig(p, XraySettings()));
      final udp =
          ((config['outbounds'] as List).first['streamSettings']
                  as Map)['finalmask']['udp'] as List;
      final mask = udp.firstWhere((m) => m['type'] == 'xdns');
      expect(mask['settings']['domains'][0]['names'], ['t.example.net']);
    });

    test('xicmp emits its typed mask with the dgram flag', () {
      final p = _vless(network: 'kcp')
        ..xicmpEnabled = true
        ..xicmpDgram = true;
      final config = _decode(buildTunnelConfig(p, XraySettings()));
      final udp =
          ((config['outbounds'] as List).first['streamSettings']
                  as Map)['finalmask']['udp'] as List;
      final mask = udp.firstWhere((m) => m['type'] == 'xicmp');
      expect(mask['settings']['dgram'], isTrue);
    });

    test('empty fields emit NO finalmask (OFF invariance)', () {
      final config = _decode(
        buildTunnelConfig(_vless(network: 'kcp'), XraySettings()),
      );
      final stream =
          (config['outbounds'] as List).first['streamSettings'] as Map;
      expect(stream.containsKey('finalmask'), isFalse);
    });

    test('xdns stays off non-kcp transports', () {
      final p = _vless(network: 'tcp')..xdnsDomain = 't.example.net';
      final config = _decode(buildTunnelConfig(p, XraySettings()));
      final stream =
          (config['outbounds'] as List).first['streamSettings'] as Map;
      expect(stream.containsKey('finalmask'), isFalse);
    });
  });

  group('build 2147 — #5 balancer config', () {
    test('a group becomes observatory + leastPing over tagged members', () {
      final members = [
        _vless(id: 'a'),
        _vless(id: 'b')..address = 'de1.example.net',
        _vless(id: 'c')..address = 'fr1.example.net',
      ];
      final config = _decode(
        buildBalancerTunnelConfig(members, XraySettings()),
      );
      final tags = (config['outbounds'] as List)
          .map((o) => o['tag'])
          .toList();
      expect(tags, containsAll(['proxy-0', 'proxy-1', 'proxy-2']));
      expect(config['observatory']['subjectSelector'], ['proxy-']);
      final balancer = (config['routing']['balancers'] as List).first;
      expect(balancer['tag'], 'proxy-balancer');
      expect(balancer['strategy']['type'], 'leastPing');
    });

    test('fewer than two servable members throws', () {
      expect(
        () => buildBalancerTunnelConfig([_vless()], XraySettings()),
        throwsStateError,
      );
    });
  });

  group('build 2147 — #6 SSH', () {
    test('an ssh link parses; the sidecar config carries the outbound', () {
      final p = parseLink('ssh://root:secret@203.0.113.7:2222#my-ssh');
      expect(p, isNotNull);
      expect(p!.protocol, Protocol.ssh);
      expect(p.sshUser, 'root');
      expect(p.sshPassword, 'secret');
      expect(p.port, 2222);
      expect(singBoxConfigError(p), isNull);
      final config = buildSingBoxConfig(p);
      final outbound = (config['outbounds'] as List).first;
      expect(outbound['type'], 'ssh');
      expect(outbound['server'], '203.0.113.7');
      expect(outbound['server_port'], 2222);
      expect(outbound['user'], 'root');
      expect(outbound['password'], 'secret');
    });

    test('ssh without a password or key is a plain-words error', () {
      final p = parseLink('ssh://root@203.0.113.7#x');
      expect(p, isNotNull);
      expect(singBoxConfigError(p!), isNotNull);
    });
  });

  group('build 2147 — #4/#16/#19 pure pieces', () {
    test('SNI results rank passers by latency, blocked last', () {
      final ranked = rankSniResults([
        (host: 'a', handshakeOk: true, firstByteMs: 300, note: ''),
        (host: 'b', handshakeOk: false, firstByteMs: -1, note: ''),
        (host: 'c', handshakeOk: true, firstByteMs: 120, note: ''),
      ]);
      expect(ranked.map((r) => r.host).toList(), ['c', 'a', 'b']);
      expect(kSniScanHosts, hasLength(30));
    });

    test('every diagnosis rung has a remedy', () {
      for (final rung in ['dns', 'tcp', 'tls', 'firstByte', 'bulk']) {
        expect(diagnosisRemedyFor(rung), isNotEmpty, reason: rung);
      }
    });

    test('the diag envelope round-trips and rejects foreign text', () {
      final env = diagExportEnvelope(
        saltB64: 'c2FsdA==',
        nonceB64: 'bm9uY2U=',
        cipherB64: 'Y2lwaGVy',
      );
      expect(env.contains(kDiagExportMagic), isTrue);
      final parsed = parseDiagEnvelope(env);
      expect(parsed, isNotNull);
      expect(parsed!.saltB64, 'c2FsdA==');
      expect(parsed.nonceB64, 'bm9uY2U=');
      expect(parsed.cipherB64, 'Y2lwaGVy');
      expect(parseDiagEnvelope('garbage'), isNull);
      expect(kDiagKdfIterations, greaterThanOrEqualTo(100000));
    });
  });
}
