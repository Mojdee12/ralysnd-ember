// Build 2065 — the single-build Iran pack: the Shir o Khorshid
// Psiphon capabilities (strategy ladder, Conduit, Beast Mode,
// CDN fronting with a ping-tested edge list, fork-core port) plus
// [Build 2069 update: Beast Mode — the one feature that needed
// the rebuilt fork core — is WITHDRAWN, and the fork core
// itself is REPLACED by ralysnd's complete stock Psiphon stack
// (v2.0.39 wrapper + libpgjni.so, transplanted byte-exact).
// The pins that asserted Beast / dial-override / CDN-scan
// presence are updated in place below and say so; the fork
// tree's own source pins are re-scoped as parked-tree records.
// Everything else stands.]
// the 15-item Iran list (CF scanner applies, per-network winner
// memory, cross-engine fallback chain, filtering probe, AWG
// handshake-noise editing + socket recovery, WARP endpoint pins,
// scheduled subscription health, TLS fingerprint rotation,
// auto-connect triggers; DNSTT / Mieru-Snell-Naive / wstunnel /
// DNSCrypt+DoT parked with evidence in BUILD-LOG-2.md).
// These pins fail on the pre-2065 code shape and pass after.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/net/network_info.dart';
import 'package:firefox_vpn/net/probe.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_strategy.dart';
import 'package:firefox_vpn/ui/ember/automation_pages.dart';
import 'package:firefox_vpn/xray/awg_uapi.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('item 1/2 — Psiphon ladder order', () {
    test('auto ladder is A,E,D,C and winner goes first', () {
      final order = psiphonRungOrder(
        method: '',
        lastWinner: 'D',
        hasEdges: true,
        hasPairing: false,
        hasUpstream: false,
      );
      expect(order.first, 'D');
      expect(order, containsAll(<String>['A', 'E', 'D', 'C']));
    });

    test('E drops without tested edges, P without pairing, X '
        'without upstream', () {
      final order = psiphonRungOrder(
        method: '',
        lastWinner: '',
        hasEdges: false,
        hasPairing: false,
        hasUpstream: false,
      );
      expect(order, ['A', 'D', 'C']);
    });

    test('a pinned method runs alone', () {
      final order = psiphonRungOrder(
        method: 'A',
        lastWinner: 'D',
        hasEdges: true,
        hasPairing: true,
        hasUpstream: true,
      );
      expect(order, ['A']);
    });
  });

  group('item 2 — CDN edge ranking and feeding', () {
    CdnEdge edge(
      String address,
      String sni,
      String provider, {
      int? ms,
      bool ok = false,
      int at = 0,
      String? testedIp,
    }) => CdnEdge(
      address: address,
      sni: sni,
      provider: provider,
      lastMs: ms,
      lastOk: ok,
      lastTestAtMs: at,
      testedIp: testedIp,
    );

    test('fastest reachable wins; failed and untested rank after', () {
      final ranked = rankCdnEdges([
        edge('10.0.0.1', 'a', 'akamai', ms: 300, ok: true, at: 5),
        edge('10.0.0.2', 'a', 'akamai', ms: 90, ok: true, at: 5),
        edge('10.0.0.3', 'a', 'akamai', at: 5), // tested, failed
        edge('10.0.0.4', 'a', 'akamai'), // never tested
      ]);
      expect(ranked.map((e) => e.address).toList(), [
        '10.0.0.2',
        '10.0.0.1',
        '10.0.0.4',
        '10.0.0.3',
      ]);
    });

    test('core feed excludes failed edges and hostnames without '
        'a probed IP', () {
      final feed = cdnEdgesForCore(
        [
          edge('10.0.0.2', 'a', 'akamai', ms: 90, ok: true, at: 5),
          edge('10.0.0.3', 'a', 'akamai', at: 5),
          edge(
            'pypi.org',
            'pypi.org',
            'fastly',
            ms: 50,
            ok: true,
            at: 5,
            testedIp: '10.0.0.9',
          ),
        ],
        autoUse: true,
        pinnedId: '',
      );
      expect(feed.akamai, ['10.0.0.2']);
      expect(feed.fastly, ['10.0.0.9']);
    });

    test('a pinned edge is fed alone when auto-use is off', () {
      final edges = [
        edge('10.0.0.2', 'a', 'akamai', ms: 90, ok: true, at: 5),
        edge('10.0.0.7', 'a', 'akamai', ms: 400, ok: true, at: 5),
      ];
      final feed = cdnEdgesForCore(
        edges,
        autoUse: false,
        pinnedId: edges[1].id,
      );
      expect(feed.akamai, ['10.0.0.7']);
    });

    test('built-in edges carry the Shir Akamai IPs and the '
        'Fastly front hosts', () {
      final builtins = builtinCdnEdges();
      expect(builtins.any((e) => e.address == '23.215.0.206'), isTrue);
      expect(
        builtins.any((e) => e.address == 'j.sni.global.fastly.net'),
        isTrue,
      );
      expect(builtins.every((e) => e.builtin), isTrue);
    });

    test('edge + winner settings survive a JSON round-trip', () {
      final s = PsiphonSettings();
      s.cdnEdges = [
        edge('10.0.0.2', 'a', 'akamai', ms: 90, ok: true, at: 5),
      ];
      s.lastMethodByNetwork['wifi:Home'] = 'E';
      final back = PsiphonSettings.fromJson(s.toJson());
      expect(back.cdnEdges.single.address, '10.0.0.2');
      expect(back.cdnEdges.single.lastMs, 90);
      expect(back.winnerFor('wifi:Home'), 'E');
      expect(back.winnerFor('mobile'), '');
    });
  });

  group('item 1 — Conduit pairing parser', () {
    test('accepts a 43-char compartment id', () {
      final id = 'A' * 43;
      final p = parseConduitPairing(id);
      expect(p, isNotNull);
      expect(p!.id, id);
    });

    test('rejects junk', () {
      expect(parseConduitPairing(''), isNull);
      expect(parseConduitPairing('short'), isNull);
      expect(parseConduitPairing('!!!not a token!!!'), isNull);
    });
  });

  group('item 1/2 — Kotlin host pins', () {
    final constants = ktSrc('PsiphonConstants.kt');
    final service = ktSrc('PsiphonVpnService.kt');

    test('server-list freshness + exchange key + anti-hijack DNS '
        'are in the constants', () {
      expect(constants.contains('REMOTE_SERVER_LIST_URLS'), isTrue);
      expect(
        constants.contains('DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU='),
        isTrue,
      );
      expect(constants.contains('208.67.222.222:5353'), isTrue);
      expect(constants.contains('9.9.9.9:9953'), isTrue);
    });

    test('the ladder carries budgets and fronting fields '
        '(fork emissions withdrawn in 2069)', () {
      expect(service.contains('runLadder'), isTrue);
      // UPDATED by build 2069 (was: AggressiveEstablishment,
      // FrontedMeekDialOverrides and
      // FrontedMeekCDNScanUseBuiltInSpec all present). Those
      // emissions belonged to the rebuilt fork core; the
      // transplanted stock core (ralysnd's v2.0.39) contains
      // NONE of those fields (0 occurrences each in its
      // string table), so the host must never emit them
      // again. The pins now assert the EMISSIONS are gone
      // (withdrawal comments may still name the fields).
      expect(service.contains('put("AggressiveEstablishment"'), isFalse);
      expect(service.contains('put("FrontedMeekDialOverrides"'), isFalse);
      expect(
          service.contains('put("FrontedMeekCDNScanUseBuiltInSpec"'), isFalse);
      expect(service.contains('put("FrontedMeekCDNScanSpec"'), isFalse);
      // Fronting itself survives the transplant through the
      // stock mechanism: preresolved provider CIDRs.
      expect(
          service.contains('put("DNSResolverPreresolvedIPAddressCIDRs"'),
          isTrue);
      expect(service.contains('RemoteServerListURLs'), isTrue);
    });

    test('no dial-override machinery remains (the mechanism '
        'was withdrawn with the fork core in 2069)', () {
      // REPLACED by build 2069 (was: 'every dial override
      // carries match criteria'). The dial-override feature
      // itself is gone — the stock core has no such field —
      // so its match-criteria strings must be gone too, not
      // merely unused.
      expect(service.contains('MatchDialAddressRegexes'), isFalse);
      expect(service.contains('MatchFrontingProviderIDRegexes'), isFalse);
      // The definition shape (the replacement helper's doc
      // names the old function in prose).
      expect(service.contains('private fun applyCdnFronting'), isFalse);
    });
  });

  group('item 1/2 — fork-core security pins (PARKED tree since '
      '2069: the shipped core is ralysnd\u2019s stock v2.0.39; these '
      'pins now record the parked fork sources, nothing shipped)',
      () {
    final dial = File(
      '../../psiphon/tunnel-core/psiphon/dialParameters.go',
    ).readAsStringSync();
    final spec = File(
      '../../psiphon/tunnel-core/psiphon/common/parameters/frontingSpec.go',
    ).readAsStringSync();

    test('the fork SkipCertVerify flag is never honoured', () {
      expect(dial.contains('override.SkipCertVerify ||'), isFalse);
      expect(spec.contains('SkipCertVerify is deliberately NOT honoured'),
          isTrue);
    });

    test('fronting exists in the PARKED tree (fronted meek '
        'CDN scan — source record only since 2069)', () {
      expect(
        File(
          '../../psiphon/tunnel-core/psiphon/frontedMeekCDNScan.go',
        ).existsSync(),
        isTrue,
      );
      final config = File(
        '../../psiphon/tunnel-core/psiphon/config.go',
      ).readAsStringSync();
      // UPDATED by build 2069 (was: the same assertion, kept
      // as a shipped-feature pin). The Beast port still EXISTS
      // in this source tree — parked, not deleted — but 2069
      // ships the STOCK core, so this line now documents the
      // port's parked presence in source only; the shipped
      // binary's stock fingerprint is pinned in
      // build2069_test.dart.
      expect(config.contains('AggressiveEstablishment'), isTrue);
    });
  });

  group('item 4 — network identity keys', () {
    test('wifi with SSID, wifi bare, mobile with carrier', () {
      expect(
        const NetworkIdentity(transport: 'wifi', ssid: 'Home').key,
        'wifi:Home',
      );
      expect(const NetworkIdentity(transport: 'wifi').key, 'wifi');
      expect(
        const NetworkIdentity(
          transport: 'mobile',
          operatorName: 'IR-MCI',
        ).key,
        'mobile:IR-MCI',
      );
    });

    test('xray winner map survives the settings round-trip', () {
      final s = XraySettings();
      s.lastProfileByNetwork['wifi:Home'] = 'p1';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.lastProfileByNetwork['wifi:Home'], 'p1');
    });
  });

  group('item 5/14 — AppSettings chain + auto-connect persistence', () {
    test('defaults: chain off with the owner order, auto-connect '
        'off', () {
      final s = AppSettings();
      expect(s.fallbackChainEnabled, isFalse);
      expect(s.fallbackChain, [2, 3, 6, 1]);
      expect(s.emberAutoConnect, isFalse);
      expect(s.trustedSsids, isEmpty);
    });
  });

  group('item 6 — probe DNS packet pins', () {
    test('a built query parses its own answer back', () {
      final q = buildDnsQuery('example.com', 0x1234);
      expect(q.length, greaterThan(12));
      // Header + question round-trip shape: the parser needs a
      // response packet; build one by flipping the QR bit and
      // appending an A answer pointing at the question.
      final resp = [...q];
      resp[2] = 0x81;
      resp[3] = 0x80;
      resp[7] = 1; // ANCOUNT = 1
      final answer = <int>[
        0xC0, 0x0C, // name pointer to the question
        0, 1, // TYPE A
        0, 1, // CLASS IN
        0, 0, 0, 60, // TTL
        0, 4, // RDLENGTH
        93, 184, 216, 34,
      ];
      final packet = Uint8List.fromList([...resp, ...answer]);
      expect(parseFirstAAnswer(packet), '93.184.216.34');
    });
  });

  group('item 8 — AWG junk parameters reach the UAPI string', () {
    test('buildAwgUapi emits jc/jmin/jmax/s1/s2/h1-h4', () {
      final p = Profile(
        id: 'wg1',
        protocol: Protocol.wireguard,
        address: '203.0.113.7',
        port: 51820,
        secretKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        peerPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        awgJc: '4',
        awgJmin: '40',
        awgJmax: '70',
        awgS1: '15',
        awgS2: '18',
        awgH1: '101',
        awgH2: '202',
        awgH3: '303',
        awgH4: '404',
      );
      final uapi = buildAwgUapi(p);
      for (final part in [
        'jc=4',
        'jmin=40',
        'jmax=70',
        's1=15',
        's2=18',
        'h1=101',
        'h2=202',
        'h3=303',
        'h4=404',
      ]) {
        expect(uapi, contains(part), reason: part);
      }
    });

    test('the editor binds all nine junk fields for editing', () {
      final editor = dartSrc('ui/ember/profile_editor.dart');
      for (final key in [
        'awgJc',
        'awgJmin',
        'awgJmax',
        'awgS1',
        'awgS2',
        'awgH1',
        'awgH2',
        'awgH3',
        'awgH4',
      ]) {
        expect(editor.contains("_text('$key'"), isTrue, reason: key);
        expect(editor.contains("..$key = _v('$key')"), isTrue, reason: key);
      }
    });

    test('the service re-applies the AWG config on network change',
        () {
      final svc = ktSrc('XrayVpnService.kt');
      expect(svc.contains('registerAwgNetworkCallback'), isTrue);
      expect(svc.contains('AwgBackend.setConfig(awgHandle, text)'), isTrue);
      expect(svc.contains('unregisterAwgNetworkCallback'), isTrue);
      expect(svc.contains('awgSettingsText = settings'), isTrue);
    });
  });

  group('item 13 — TLS fingerprint rotation', () {
    Profile tlsProfile({String fingerprint = ''}) => Profile(
      id: 't1',
      protocol: Protocol.vless,
      address: 'example.com',
      port: 443,
      uuidOrPassword: '00000000-0000-0000-0000-000000000000',
      security: 'tls',
      fingerprint: fingerprint,
    );

    Map<String, dynamic> outboundOf(String json) {
      final cfg = jsonDecode(json) as Map<String, dynamic>;
      return (cfg['outbounds'] as List).first as Map<String, dynamic>;
    }

    test('rotation fills an empty fingerprint from the cursor', () {
      final s = XraySettings()
        ..rotateTlsFingerprint = true
        ..tlsFingerprintIndex = 1;
      final out = outboundOf(buildTunnelConfig(tlsProfile(), s));
      final tls =
          (out['streamSettings'] as Map<String, dynamic>)['tlsSettings']
              as Map<String, dynamic>;
      expect(tls['fingerprint'], 'firefox');
    });

    test('a pinned profile fingerprint is never overridden', () {
      final s = XraySettings()
        ..rotateTlsFingerprint = true
        ..tlsFingerprintIndex = 1;
      final out = outboundOf(
        buildTunnelConfig(tlsProfile(fingerprint: 'chrome'), s),
      );
      final tls =
          (out['streamSettings'] as Map<String, dynamic>)['tlsSettings']
              as Map<String, dynamic>;
      expect(tls['fingerprint'], 'chrome');
    });

    test('rotation off emits no fingerprint key', () {
      final s = XraySettings();
      final out = outboundOf(buildTunnelConfig(tlsProfile(), s));
      final tls =
          (out['streamSettings'] as Map<String, dynamic>)['tlsSettings']
              as Map<String, dynamic>;
      expect(tls.containsKey('fingerprint'), isFalse);
      expect(effectiveFingerprint(tlsProfile(), s, rotationIndex: 2), '');
    });
  });

  group('item 14 — boot receiver wiring', () {
    test('manifest + receiver record the boot, start nothing', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest.contains('RECEIVE_BOOT_COMPLETED'), isTrue);
      expect(manifest.contains('BootReceiver'), isTrue);
      final receiver = ktSrc('BootReceiver.kt');
      expect(receiver.contains('bootPending'), isTrue);
      expect(receiver.contains('startService'), isFalse);
      expect(receiver.contains('startForegroundService'), isFalse);
    });

    test('the platform channel exposes network info + boot '
        'consumption', () {
      final main = ktSrc('MainActivity.kt');
      expect(main.contains('networkChanged'), isTrue);
      expect(main.contains('"networkInfo"'), isTrue);
      expect(main.contains('"consumeBootPending"'), isTrue);
    });
  });

  group('item 3/10 — scanner + WARP pins', () {
    test('the CF page offers WARP + Psiphon applies and resolves '
        'neighbours for any host', () {
      final page = dartSrc('ui/ember/cf_scanner_page.dart');
      expect(page.contains('As the WARP endpoint'), isTrue);
      expect(page.contains('As a Psiphon CDN edge'), isTrue);
      expect(page.contains('workers.dev\')'), isFalse);
    });

    test('known WARP endpoints exist and the settings page pins '
        'them', () {
      final args = dartSrc('xray/warp_args.dart');
      expect(args.contains('162.159.192.1:2408'), isTrue);
      expect(args.contains('188.114.97.1:2408'), isTrue);
      final page = dartSrc('ui/ember/warp_settings_page.dart');
      expect(page.contains('kKnownWarpEndpoints'), isTrue);
    });
  });

  group('item 5 — shell chain wiring', () {
    test('the power capsule routes through the chain and the '
        'chain status renders', () {
      final shell = dartSrc('ui/ember/ember_shell.dart');
      expect(shell.contains('_connectWithChain'), isTrue);
      expect(shell.contains('_powerToggle'), isTrue);
      expect(shell.contains('_chainStatus'), isTrue);
      expect(shell.contains('rememberWinnerForNetwork'), isTrue);
    });
  });

  group('widgets — automation pages render', () {
    testWidgets('fallback chain page shows the owner order',
        (tester) async {
      final s = AppSettings();
      await tester.pumpWidget(
        MaterialApp(home: FallbackChainPage(settings: s)),
      );
      await tester.pump();
      expect(find.text('Psiphon'), findsWidgets);
      expect(find.text('Lantern'), findsWidgets);
      expect(find.text('WARP'), findsWidgets);
      expect(find.text('V2Ray'), findsWidgets);
    });

    testWidgets('auto-connect page renders with master off',
        (tester) async {
      final s = AppSettings();
      await tester.pumpWidget(
        MaterialApp(home: AutoConnectPage(settings: s)),
      );
      await tester.pump();
      expect(find.text('Auto-connect'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('TRUSTED WI-FI NETWORKS'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('TRUSTED WI-FI NETWORKS'), findsOneWidget);
    });
  });
}
