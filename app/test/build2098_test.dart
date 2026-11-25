// Build 2098 — regression/behavioural coverage for the
// post-2097 audit's 48 findings, the updater root-cause
// pass (Item C + U-A + L30), the Settings Logs entry
// (Item B), the AmneziaWG I1–I5/J1–J3 preservation fix
// (Item A), and the WARP endpoint scanner. Behavioural
// wherever the surface allows; the probe's handshake is
// additionally proven against a real amneziawg-go device
// by the development harness (see BUILD-LOG-2.md).

import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/core/system_ui_flight.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_logs_page.dart';
import 'package:firefox_vpn/ui/ember/wg_scan_page.dart';
import 'package:firefox_vpn/ui/ember/xray_logs_page.dart';
import 'package:firefox_vpn/openvpn/openvpn_platform.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/profile_validation.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/wg_probe.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/xray_platform.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String s) => Uint8List.fromList(
  List.generate(
    s.length ~/ 2,
    (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16),
  ),
);

/// The dummy-key same-shape fixture for Item A: a WARP
/// config carrying Jc/Jmin/Jmax and an AWG-2.0 I1 DSL —
/// the shape of the owner's crashing config, with fake
/// key material only.
const _awgConf = '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 172.16.0.2/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = 188.114.96.125:2408
PersistentKeepalive = 25
Jc = 6
Jmin = 10
Jmax = 50
I1 = <r 2><b 0x8580aabbccdd>
''';

int _wgIds = 0;
Profile _warpProfile() => parseWgConf(
  _awgConf,
  baseName: 'Warp fixture',
  idFor: () => 'wg${++_wgIds}',
).profiles.single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('probe crypto — independent vectors', () {
    test('blake2s256 matches the reference digests', () {
      expect(
        _hex(blake2s256(const [])),
        '69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9',
      );
      expect(
        _hex(blake2s256(utf8.encode('abc'))),
        '508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982',
      );
    });

    test('keyed blake2s (the mac1 form) matches', () {
      final key = List<int>.generate(32, (i) => i);
      expect(
        _hex(blake2s(const [], key: key)),
        '48a8997da407876b3d79c0d92325ad3b89cbb754d86ab71aee047ad345fd2c49',
      );
      expect(
        _hex(blake2s(utf8.encode('abc'), key: key)),
        'a281f725754969a702f6fe36fc591b7def866e4b70173ece402fc01c064d6b65',
      );
      expect(
        _hex(blake2s(utf8.encode('hello'), key: key, outLen: 16)),
        '1f946dc212a39570bc06fd378517a91e',
      );
    });

    test('x25519 matches RFC 7748', () {
      final scalar = _unhex(
        'a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4',
      );
      final u = _unhex(
        'e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c',
      );
      expect(
        _hex(x25519(scalar, u)),
        'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552',
      );
      final alicePriv = _unhex(
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
      );
      expect(
        _hex(x25519Public(alicePriv)),
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
      );
    });
  });

  group('probe packet building', () {
    test('DSL builder: data tags, waits, and refusals', () {
      AwgDslPacket build(String dsl) => buildAwgDslPacket(
        dsl,
        random: Random(7),
        counter: 0,
        now: DateTime.now(),
      );
      expect(build('<b 0x8580>').bytes, [0x85, 0x80]);
      expect(build('<r 2><b 0x8580>').bytes.length, 4);
      final t = build('<t>');
      expect(t.bytes.length, 8);
      final secs = ByteData.sublistView(
        Uint8List.fromList(t.bytes),
      ).getUint64(0, Endian.big);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect((secs - now).abs(), lessThan(5));
      expect(build('<c>').bytes.length, 8);
      // A wait tag emits no bytes of its own.
      final wt = build('<wt 5><b 0x01>');
      expect(wt.bytes, [0x01]);
      expect(wt.waitBefore, const Duration(milliseconds: 5));
      expect(() => build('<x 1>'), throwsFormatException);
      expect(() => build('<b zz>'), throwsFormatException);
      expect(() => build('<r 1001>'), throwsFormatException);
    });

    test('pre-packets: I-packet leads, junk follows, plain is empty', () {
      final awg = _warpProfile();
      final packets = awgPrePackets(awg, random: Random(3));
      // 1 signature packet + Jc (6) junk packets.
      expect(packets.length, 7);
      expect(packets.first.bytes.length, 2 + 6); // <r 2> + 6 hex bytes
      for (final junk in packets.skip(1)) {
        expect(junk.bytes.length, inInclusiveRange(10, 50));
      }
      final plain = parseWgConf(
        '''
[Interface]
PrivateKey = YAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.0.0.2/32
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = 188.114.96.125:2408
''',
        baseName: 'Plain',
        idFor: () => 'wgplain',
      ).profiles.single;
      expect(awgPrePackets(plain, random: Random(3)), isEmpty);
    });

    test('initiation shape: plain 148, S1 prefix, H1 type word', () {
      final plain = _warpProfile()
        ..awgJc = ''
        ..awgI1 = ''
        ..awgS1 = '';
      final init = buildWgInitiation(plain);
      expect(init.prePackets, isEmpty);
      expect(init.datagram.length, 148);
      expect(init.datagram[0], 1);

      final s1 = _warpProfile()..awgS1 = '20';
      final initS1 = buildWgInitiation(s1);
      expect(initS1.datagram.length, 20 + 148);

      final h1 = _warpProfile()..awgH1 = '305419896'; // 0x12345678
      final initH1 = buildWgInitiation(h1);
      final head = ByteData.sublistView(initH1.datagram);
      expect(head.getUint32(0, Endian.little), 0x12345678);
    });
  });

  group('probe interop — a spec-written responder verifies', () {
    // A third implementation of the responder chain,
    // written from the Noise_IKpsk2 transcript the device
    // runs (CreateMessageResponse in noise-protocol.go):
    // it consumes the probe's initiation and produces a
    // response the probe's verifier must accept. The
    // shared primitives are pinned by the RFC/reference
    // vectors above; this test pins the COMPOSITION
    // (mixHash/mixKey order, labels, MACs) — the class of
    // error a real device rejects with "invalid
    // initiation message".
    test('initiation is consumed and the response verifies', () {
      final profile = _warpProfile()
        ..awgJc = ''
        ..awgI1 = '';
      // Responder identity: private = bytes 200..231.
      final respPriv = Uint8List.fromList(
        List.generate(32, (i) => 200 + i),
      );
      final respPub = x25519Public(respPriv);
      profile.peerPublicKey = base64Encode(respPub);

      final init = buildWgInitiation(profile);
      final packet = init.datagram;
      expect(packet.length, 148);

      Uint8List h(List<int> data) => blake2s256(data);
      var hash = h([...blake2s256(utf8.encode(_wgConstruction)), ..._wgId]);
      hash = h([...hash, ...respPub]);
      var chain = blake2s256(utf8.encode(_wgConstruction));
      final ephPub = Uint8List.sublistView(packet, 8, 40);
      hash = h([...hash, ...ephPub]);
      chain = _kdf1(chain, ephPub);
      var key = _kdf2(chain, x25519(respPriv, ephPub));
      chain = key.$1;
      final staticOpened = _open(
        key.$2,
        Uint8List.sublistView(packet, 40, 88),
        hash,
      );
      expect(staticOpened, isNotNull);
      final initiatorPub = Uint8List.fromList(staticOpened!);
      hash = h([...hash, ...Uint8List.sublistView(packet, 40, 88)]);
      key = _kdf2(chain, x25519(respPriv, initiatorPub));
      chain = key.$1;
      final tsOpened = _open(
        key.$2,
        Uint8List.sublistView(packet, 88, 116),
        hash,
      );
      expect(tsOpened, hasLength(12));
      hash = h([...hash, ...Uint8List.sublistView(packet, 88, 116)]);

      // Build the response.
      final respEphPriv = Uint8List.fromList(
        List.generate(32, (i) => 77 + i),
      );
      final respEphPub = x25519Public(respEphPriv);
      const receiverIndex = 424242;
      final senderIndex = ByteData.sublistView(packet).getUint32(
        4,
        Endian.little,
      );
      hash = h([...hash, ...respEphPub]);
      chain = _kdf1(chain, respEphPub);
      chain = _kdf1(chain, x25519(respEphPriv, ephPub));
      chain = _kdf1(chain, x25519(respEphPriv, initiatorPub));
      final kdf3 = _kdf3(chain, Uint8List(32));
      hash = h([...hash, ...kdf3.$2]);
      final encEmpty = _seal(kdf3.$3, const [], hash);
      final response = Uint8List(92);
      final rbd = ByteData.sublistView(response);
      rbd.setUint32(0, 2, Endian.little);
      rbd.setUint32(4, receiverIndex, Endian.little);
      rbd.setUint32(8, senderIndex, Endian.little);
      response.setRange(12, 44, respEphPub);
      response.setRange(44, 60, encEmpty);
      final macKey = blake2s256([
        ...utf8.encode('mac1----'),
        ...initiatorPub,
      ]);
      response.setRange(
        60,
        76,
        blake2s(
          Uint8List.sublistView(response, 0, 60),
          key: macKey,
          outLen: 16,
        ),
      );

      expect(verifyWgResponse(profile, init, response), receiverIndex);
      // A tampered response must NOT verify.
      final bad = Uint8List.fromList(response)..[20] ^= 0xFF;
      expect(verifyWgResponse(profile, init, bad), isNull);
    });
  });

  group('scanner model', () {
    test('candidates: current first, bounded, deduped, WARP ranges', () {
      final profile = _warpProfile();
      final cands = warpScanCandidates(profile);
      expect(cands.first, (profile.address, profile.port));
      expect(cands.length, 209); // 208 sampled + the current endpoint
      expect(cands.toSet().length, cands.length);
      for (final (ip, port) in cands) {
        expect(port, anyOf(2408, 500));
        final o = ip.split('.').map(int.parse).toList();
        final inRanges =
            (o[0] == 188 && o[1] == 114 && o[2] >= 96 && o[2] <= 99) ||
            (o[0] == 162 && o[1] == 159 && (o[2] == 192 || o[2] == 195)) ||
            (o[0] == 8 &&
                ((o[1] == 6 && o[2] == 112) ||
                    (o[1] == 34 && (o[2] == 70 || o[2] == 146)) ||
                    (o[1] == 35 && o[2] == 211) ||
                    (o[1] == 39 &&
                        (o[2] == 125 || o[2] == 204 || o[2] == 214)) ||
                    (o[1] == 47 && o[2] == 69)));
        expect(inRanges, isTrue, reason: ip);
      }
    });

    test('results sort ascending and dedupe by fastest', () {
      final sorted = sortScanResults(const [
        WgScanResult(address: '1.1.1.1', port: 2408, handshakeMs: 300),
        WgScanResult(address: '2.2.2.2', port: 500, handshakeMs: 120),
        WgScanResult(address: '1.1.1.1', port: 2408, handshakeMs: 200),
      ]);
      expect(sorted.map((r) => r.endpoint), ['2.2.2.2:500', '1.1.1.1:2408']);
      expect(sorted.last.handshakeMs, 200);
    });
  });

  group('Item A — the AWG signature family survives everything', () {
    test('conf parse keeps I1 and the junk params', () {
      final p = _warpProfile();
      expect(p.awgJc, '6');
      expect(p.awgJmin, '10');
      expect(p.awgJmax, '50');
      expect(p.awgI1, '<r 2><b 0x8580aabbccdd>');
      expect(p.hasAmneziaParams, isTrue);
    });

    test('the engine hand-off carries I1 (the engine applies it)', () {
      // Build 2104: the hand-off is wgConfFromProfile's .conf
      // text (the UAPI composer is deleted with the old
      // bridge); the WG Tunnel parser reads I1 from it and
      // its amneziawg-go v3 device sends the signature
      // packet — the property this test exists to pin.
      final conf = wgConfFromProfile(_warpProfile());
      expect(conf, contains('I1 = <r 2><b 0x8580aabbccdd>'));
      expect(conf, contains('Jc = 6'));
    });

    test('conf re-emission and JSON round-trip keep I1', () {
      final p = _warpProfile();
      expect(wgConfFromProfile(p), contains('I1 = <r 2><b 0x8580aabbccdd>'));
      final back = Profile.fromJson(p.toJson());
      expect(back.awgI1, p.awgI1);
      expect(back.awgJ2, p.awgJ2);
    });

    test('the link codec carries the signature family', () {
      final p = _warpProfile();
      final link = profileToLink(p);
      expect(link, startsWith('wireguard://'));
      expect(link, contains('i1='));
      final back = parseLink(link);
      expect(back, isNotNull);
      expect(back!.awgI1, p.awgI1);
    });

    test('the connect config path builds without throwing', () {
      // buildTunnelConfig is the exact config-building
      // path a connect runs (profile → tunnel config).
      expect(
        () => buildTunnelConfig(_warpProfile(), XraySettings()),
        returnsNormally,
      );
    });

    test('sanitizeAwgDsl strips line breaks and caps length', () {
      expect(sanitizeAwgDsl('<r 2>\n<b 0x85>\r\n'), '<r 2><b 0x85>');
      expect(sanitizeAwgDsl('x' * 5000).length, 4096);
      // The numeric sanitizer must never see a DSL value:
      // a DSL in a numeric field position stays a string
      // operation only (covered by the parse tests above).
    });
  });

  group('M10 — import sanitizer honesty', () {
    Profile mk(Protocol proto, String security) => Profile(
      id: 'x',
      protocol: proto,
      address: '203.0.113.1',
      security: security,
    );

    test('shadowsocks/socks/http lose an impossible security', () {
      expect(
        sanitizeImportedProfile(mk(Protocol.shadowsocks, 'tls')).security,
        '',
      );
      expect(
        sanitizeImportedProfile(mk(Protocol.shadowsocks, 'reality'))
            .security,
        '',
      );
      expect(sanitizeImportedProfile(mk(Protocol.socks, 'tls')).security, '');
      expect(sanitizeImportedProfile(mk(Protocol.http, 'reality')).security, '');
    });

    test('protocols that can carry it keep their security', () {
      expect(sanitizeImportedProfile(mk(Protocol.vless, 'tls')).security, 'tls');
      expect(
        sanitizeImportedProfile(mk(Protocol.vless, 'reality')).security,
        'reality',
      );
      expect(sanitizeImportedProfile(mk(Protocol.trojan, 'tls')).security, 'tls');
    });
  });

  group('L9 — the body fall-through does not re-parse Clash', () {
    const clashDoc = '''
proxies:
  - name: clash-node
    type: ss
    server: 198.51.100.7
    port: 8388
    cipher: aes-256-gcm
    password: pw
''';

    test('skipClash leaves a Clash body to the Clash path', () {
      expect(parseSubscription(clashDoc), isNotEmpty);
      expect(parseSubscription(clashDoc, skipClash: true), isEmpty);
    });
  });

  group('M14 — the prune plan rescues active AND selected', () {
    Profile mk(String id, int delay) => Profile(
      id: id,
      protocol: Protocol.vless,
      address: '203.0.113.1',
      delayMs: delay,
    );

    test('both rescues survive the cut', () {
      final scope = [
        mk('fast1', 50),
        mk('fast2', 80),
        mk('mid', 150),
        mk('slowActive', 900),
        mk('slowSelected', 950),
      ];
      final plan = planFastestPrune(
        scope,
        2,
        activeId: 'slowActive',
        selectedId: 'slowSelected',
      );
      final removedIds = plan.remove.map((p) => p.id).toSet();
      expect(removedIds, {'mid'});
      expect(plan.keep.map((p) => p.id).toSet(), {
        'fast1',
        'fast2',
        'slowActive',
        'slowSelected',
      });
    });
  });

group('store protections (M11/M12/M13)', () {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ember2098');
    // Build 2125 note: load() now starts the geo install
    // without awaiting it (A25-22), so a background writer
    // can still be landing files when a test ends; the
    // delete retries briefly instead of failing the test
    // on the race.
    addTearDown(() async {
      for (var i = 0; i < 20; i++) {
        try {
          await tmp.delete(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    _mockAndroidChannel({'dataDir': (_) => '${tmp.path}/core'});
  });

  Future<File> seedStore(String text) async {
    final f = File('${tmp.path}/xray/state.json');
    await f.parent.create(recursive: true);
    await f.writeAsString(text);
    return f;
  }

  test('M11: export refuses while the store is a newer build\u2019s', () async {
    await seedStore('{"schemaVersion":2,"profiles":[]}');
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    expect(await c.exportBackup(), isNull);
  });

  test('M13: a foreign document is protected, never overwritten', () async {
    final f = await seedStore('{"otherAppSettings":{"x":1}}');
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    expect(c.profiles, isEmpty);
    expect(c.storeError, isNotNull);
    await c.addProfile(
      Profile(id: 'new', protocol: Protocol.vless, address: '203.0.113.1'),
    );
    final after = await f.readAsString();
    expect(after, contains('otherAppSettings'));
  });

  test('M13: a wrong-shaped core payload is protected too', () async {
    final f = await seedStore('{"profiles":"garbage","settings":42}');
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    expect(c.storeError, isNotNull);
    await c.addProfile(
      Profile(id: 'new', protocol: Protocol.vless, address: '203.0.113.1'),
    );
    final after = await f.readAsString();
    expect(after, contains('garbage'));
  });

  test('M13: a near-empty but genuine document still saves', () async {
    final f = await seedStore('{"schemaVersion":1}');
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    await c.addProfile(
      Profile(id: 'kept', protocol: Protocol.vless, address: '203.0.113.1'),
    );
    final after = await f.readAsString();
    expect(after, contains('kept'));
  });

  test('F-A4: a newer-build store keeps its guidance when misshapen', () async {
    await seedStore('{"schemaVersion":2,"profiles":"garbage","settings":42}');
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    expect(c.storeError, isNotNull);
    expect(c.storeError, contains('newer'));
    expect(c.storeError, isNot(contains('expected format')));
  });

  test('F-A1: a mixed paste still imports its Clash block', () async {
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    // One valid link line (which breaks the YAML document
    // as a whole) plus a Clash block. The whole-paste Clash
    // probe yields nothing; the leftover block alone is a
    // valid Clash document and must still import. The
    // entries are flow-style single lines — the shape that
    // survives the per-line trim of the detailed link parse
    // into the leftover set.
    final res = await c.importLinksAsync(
      'vless://11111111-1111-1111-1111-111111111111@h.example:443#link-node\n'
      'proxies:\n'
      '  - {name: clash-node, type: ss, server: 198.51.100.7, port: 8388, '
      'cipher: aes-256-gcm, password: <redacted>}',
    );
    expect(res.added, 2);
    expect(c.profiles.any((p) => p.address == '198.51.100.7'), isTrue);
    expect(c.profiles.any((p) => p.address == 'h.example'), isTrue);
    // The import's store save lands asynchronously (long-
    // standing behaviour); wait for it so the group
    // teardown's directory delete does not race the write.
    final storeFile = File('${tmp.path}/xray/state.json');
    for (var i = 0; i < 50 && !await storeFile.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('I2-A2: a block-style Clash block imports from a mixed paste',
      () async {
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    // The common panel shape: entries as indented blocks.
    // The per-line trim of the detailed link parse used to
    // destroy the indentation before the leftover document
    // parse ever saw it, so only flow-style entries (the
    // F-A1 shape above) survived a mixed paste.
    final res = await c.importLinksAsync(
      'vless://11111111-1111-1111-1111-111111111111@h.example:443#link-node\n'
      'proxies:\n'
      '  - name: clash-a\n'
      '    type: vmess\n'
      '    server: 198.51.100.9\n'
      '    port: 443\n'
      '    uuid: 11111111-2222-3333-4444-555555555555\n'
      '    alterId: 0\n'
      '    cipher: auto\n'
      '    udp: true\n'
      '  - name: clash-b\n'
      '    type: trojan\n'
      '    server: 198.51.100.10\n'
      '    port: 443\n'
      '    password: pw-b',
    );
    expect(res.added, 3, reason: '${res.errors}');
    expect(c.profiles.any((p) => p.address == '198.51.100.9'), isTrue);
    expect(c.profiles.any((p) => p.address == '198.51.100.10'), isTrue);
    // I2-A4: the entries' field-only lines (udp: true)
    // belong to the document — they are not "unread".
    expect(
      res.errors.where((e) => e.contains('could not be read')),
      isEmpty,
    );
    final storeFile = File('${tmp.path}/xray/state.json');
    for (var i = 0; i < 50 && !await storeFile.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('M12: a 1e999 numeric field degrades instead of dropping', () async {
    await seedStore(
      '{"schemaVersion":1,"profiles":[{"id":"p1","protocol":"wireguard",'
      '"address":"203.0.113.9","mtu":1e999}],"subscriptions":[],'
      '"settings":{}}',
    );
    final c = XrayController();
    addTearDown(c.dispose);
    await c.load();
    expect(c.profiles.map((p) => p.id), ['p1']);
    expect(c.profiles.single.mtu, 1420);
  });
});

group('verification iteration 1 — Aether F4', () {
  test('disconnect re-tears-down a TUN that rises late', () async {
    // The platform script: the TUN reports up, and only the
    // SECOND setTun(off) actually drops it — a connect in
    // its bring-up raised it after the disconnect's first
    // teardown was processed. The M6 ownership gate refuses
    // the connect's own teardown by then, so the disconnect
    // (the claim owner) must re-issue it while polling.
    var tunUp = true;
    var offCalls = 0;
    _mockAndroidChannel({
      'xrayState': (_) => {
        'running': tunUp,
        'name': 'WARP',
        'sinceMs': 0,
        'up': 0,
        'down': 0,
      },
      'aetherState': (_) => {'running': false},
      'socksTunSetOn': (call) {
        final args = call.arguments as Map;
        if (args['on'] == false) {
          offCalls++;
          if (offCalls >= 2) tunUp = false;
        }
        return null;
      },
      'aetherStop': (_) => null,
    });
    final c = AetherController('cfwarp');
    addTearDown(c.dispose);
    final sw = Stopwatch()..start();
    await c.disconnect();
    expect(offCalls, greaterThanOrEqualTo(2));
    expect(c.tunRunning, isFalse);
    expect(sw.elapsed, lessThan(const Duration(seconds: 9)));
  });

  test('disconnect leaves a foreign TUN alone (iteration 2)', () async {
    // The TUN is shared: an Xray session's TUN (resumed
    // from its notification, say) is not this disconnect's
    // to drop, and its presence must not keep the poll
    // alive either. The engine is down and the TUN carries
    // a profile's name, so the disconnect finishes after
    // its entry teardown and one poll.
    var offCalls = 0;
    _mockAndroidChannel({
      'xrayState': (_) => {
        'running': true,
        'name': 'some-profile',
        'sinceMs': 0,
        'up': 0,
        'down': 0,
      },
      'aetherState': (_) => {'running': false},
      'socksTunSetOn': (call) {
        final args = call.arguments as Map;
        if (args['on'] == false) offCalls++;
        return null;
      },
      'aetherStop': (_) => null,
    });
    final c = AetherController('cfwarp');
    addTearDown(c.dispose);
    final sw = Stopwatch()..start();
    await c.disconnect();
    expect(offCalls, 1);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('the poller stops when its claim is stolen (iteration 2)', () {
    final src = File('lib/aether/aether_controller.dart').readAsStringSync();
    final dc = src.indexOf('Future<void> disconnect()');
    expect(dc, greaterThan(0));
    final body = src.substring(dc, dc + 4500);
    expect(body, contains('if (!identical(_busyToken, busyToken)) return;'));
    expect(body, contains('tunName == displayName'));
  });
});

group('M9 — a busy picker is a benign no-op', () {
  test('XrayPlatform.pickTextFile returns null on busy', () async {
    _mockAndroidChannel({
      'pickTextFile': (_) =>
          throw PlatformException(code: 'busy', message: 'busy'),
    });
    expect(await XrayPlatform.pickTextFile(), isNull);
  });

  test('XrayPlatform.saveTextFile returns null on busy', () async {
    // Verification V-5: busy is not a cancel — null tells
    // the caller to report nothing (the first save is still
    // open and will report for itself).
    _mockAndroidChannel({
      'saveTextFile': (_) =>
          throw PlatformException(code: 'busy', message: 'busy'),
    });
    expect(await XrayPlatform.saveTextFile('a.txt', 'x'), isNull);
  });

  test('OpenVpnPlatform.pickFile returns null on busy', () async {
    _mockAndroidChannel({
      'openVpnPickFile': (_) =>
          throw PlatformException(code: 'busy', message: 'busy'),
    });
    expect(await OpenVpnPlatform.pickFile(), isNull);
  });
});
  group('updater — Item C, U-A, U-B, L30', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ember2098u');
      addTearDown(() => tmp.delete(recursive: true));
    });

    Map<String, dynamic> releaseJson(String tag) => {
      'tag_name': tag,
      'name': 'Ralysnd Ember $tag',
      'assets': [
        {
          'name': 'RalysndEmber2.apk',
          'browser_download_url': 'http://127.0.0.1/RalysndEmber2.apk',
          'size': 4,
        },
      ],
    };

    Future<EmberUpdater> mkUpdater({
      HttpClient Function()? clientFactory,
      Future<String> Function(Uri)? fetcher,
      Duration stall = const Duration(seconds: 30),
    }) async {
      final settings = await AppSettings.load(tmp.path);
      return EmberUpdater(
        settings: settings,
        dataDir: tmp.path,
        clientFactory: clientFactory,
        fetcher: fetcher,
        stallTimeout: stall,
      );
    }

    test('Item C: the package build, not the define, decides', () async {
      final u = await mkUpdater(
        fetcher: (_) async => jsonEncode(releaseJson('v2099')),
      );
      u.packageBuild = 2099;
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.upToDate);
      final u2 = await mkUpdater(
        fetcher: (_) async => jsonEncode(releaseJson('v2099')),
      );
      u2.packageBuild = 2098;
      await u2.check(manual: true);
      expect(u2.state, EmberUpdateState.available);
    });

    test('U-B: an unusable payload errors WITHOUT stamping the throttle',
        () async {
      var calls = 0;
      final u = await mkUpdater(
        fetcher: (_) async {
          calls++;
          return '{"message":"API rate limit exceeded"}';
        },
      );
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.error);
      expect(u.settings.lastEmberUpdateCheckMs, 0);
      await u.check(manual: true);
      expect(calls, 2, reason: 'no stamp -> the retry really retries');
    });

    test('U-B contrast: a usable payload DOES stamp', () async {
      final u = await mkUpdater(
        fetcher: (_) async => jsonEncode(releaseJson('v2099')),
      );
      u.packageBuild = 2099;
      await u.check(manual: true);
      expect(u.settings.lastEmberUpdateCheckMs, greaterThan(0));
    });

    test('U-A: proxy first while a session is up, direct as fallback',
        () async {
      final attempts = <bool>[];
      final u = await mkUpdater(
        clientFactory: () {
          final viaProxy = attempts.length == 0;
          attempts.add(false);
          return _FakeHttpClient(
            onProxySet: () => attempts[attempts.length - 1] = true,
            handler: viaProxy
                ? () => throw const SocketException('proxy down')
                : () async => _FakeResponse.ok(
                    utf8.encode(jsonEncode(releaseJson('v2099'))),
                  ),
          );
        },
      );
      u.localProxyResolver = () => '127.0.0.1:9999';
      u.packageBuild = 2098;
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.available);
      expect(attempts, [true, false],
          reason: 'first attempt proxied, second direct');
    });

    test('U-A: a working proxy means direct is never tried', () async {
      var clients = 0;
      final u = await mkUpdater(
        clientFactory: () {
          clients++;
          return _FakeHttpClient(
            handler: () async => _FakeResponse.ok(
              utf8.encode(jsonEncode(releaseJson('v2099'))),
            ),
          );
        },
      );
      u.localProxyResolver = () => '127.0.0.1:9999';
      u.packageBuild = 2098;
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.available);
      expect(clients, 1);
    });

    test('L30: a feed that connects then goes silent fails fast', () async {
      final u = await mkUpdater(
        stall: const Duration(milliseconds: 300),
        clientFactory: () => _FakeHttpClient(
          handler: () async => _FakeResponse.silent(),
        ),
      );
      final sw = Stopwatch()..start();
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.error);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('V-4: the download stall bound is longer than the feed bound', () async {
      // A >30 s byte gap mid-download (handover, tunnel
      // reconnect) must not discard a ~148 MB transfer that
      // has no resume; the feed keeps the tight bound.
      final u = await mkUpdater();
      expect(u.stallTimeout, const Duration(seconds: 30));
      expect(u.downloadStallTimeout, const Duration(seconds: 90));
    });
  });

  group('Item B + scanner pages', () {
    testWidgets('the Logs hub lists every engine and navigates', (
      tester,
    ) async {
      _mockAndroidChannel({'dataDir': (_) => '/tmp/ember2098logs/core'});
      final core = CoreController(
        () async => throw const CoreUnavailable(CoreProblem.refused, 'test'),
      );
      addTearDown(core.dispose);
      final xray = XrayController();
      addTearDown(xray.dispose);
      final psiphon = PsiphonController();
      addTearDown(psiphon.dispose);
      final lantern = LanternController();
      addTearDown(lantern.dispose);
      final openvpn = OpenVpnController();
      addTearDown(openvpn.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: EmberLogsPage(
            core: core,
            xray: xray,
            psiphon: psiphon,
            lantern: lantern,
            openvpn: openvpn,
          ),
        ),
      );
      await tester.pump();
      for (final label in [
        'V2Ray & WireGuard',
        'OpenVPN',
        'Lantern',
        'Psiphon',
        'Mozilla',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('V2Ray & WireGuard'));
      // The logs page polls on a timer (it never settles),
      // so pump fixed frames instead of pumpAndSettle.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(XrayLogsPage), findsOneWidget);
    });

    testWidgets('the scan page refuses a non-WARP peer honestly', (
      tester,
    ) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = _warpProfile()
        ..peerPublicKey = 'HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=';
      await tester.pumpWidget(
        MaterialApp(home: WgScanPage(xray: xray, profile: p)),
      );
      await tester.pump();
      expect(find.textContaining('not a WARP peer'), findsOneWidget);
      expect(find.text('Start scan'), findsNothing);
    });

    testWidgets('the scan page offers a scan for a WARP config', (
      tester,
    ) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      await tester.pumpWidget(
        MaterialApp(home: WgScanPage(xray: xray, profile: _warpProfile())),
      );
      await tester.pump();
      expect(find.text('Start scan'), findsOneWidget);
    });
  });

  group('L28 — a stranded flight stops suppressing the re-lock', () {
    setUp(SystemUiFlight.resetForTest);
    tearDown(SystemUiFlight.resetForTest);

    test('a live flight suppresses, a finished one does not', () {
      expect(SystemUiFlight.suppressesRelock, isFalse);
      SystemUiFlight.begin();
      expect(SystemUiFlight.inFlight, isTrue);
      expect(SystemUiFlight.stranded, isFalse);
      expect(SystemUiFlight.suppressesRelock, isTrue);
      SystemUiFlight.end();
      expect(SystemUiFlight.suppressesRelock, isFalse);
    });

    test('a flight older than the bound is stranded', () {
      SystemUiFlight.begin();
      SystemUiFlight.ageCurrentFlightForTest(
        SystemUiFlight.strandedAfter + const Duration(minutes: 1),
      );
      expect(SystemUiFlight.inFlight, isTrue);
      expect(SystemUiFlight.stranded, isTrue);
      expect(SystemUiFlight.suppressesRelock, isFalse);
      SystemUiFlight.end();
      SystemUiFlight.begin();
      expect(SystemUiFlight.stranded, isFalse);
      expect(SystemUiFlight.suppressesRelock, isTrue);
      SystemUiFlight.end();
    });

    test('V-6: a fresh flight after a stranded one is protected', () {
      // The stranded begin never ends (IMP-R). A NEW pick
      // beginning afterwards must be judged by its own age,
      // not inherited from the stranded flight — with the
      // first-begin anchor it snapshotted as stranded at its
      // own pause and lost its re-lock protection.
      SystemUiFlight.begin();
      SystemUiFlight.ageCurrentFlightForTest(
        SystemUiFlight.strandedAfter + const Duration(minutes: 1),
      );
      expect(SystemUiFlight.stranded, isTrue);
      expect(SystemUiFlight.suppressesRelock, isFalse);
      SystemUiFlight.begin();
      expect(SystemUiFlight.stranded, isFalse);
      expect(SystemUiFlight.suppressesRelock, isTrue);
      SystemUiFlight.end();
      // Iteration 2: the fresh flight has ended; the
      // stranded one underneath is exposed again — it must
      // not keep borrowing the fresh flight's youth.
      expect(SystemUiFlight.stranded, isTrue);
      expect(SystemUiFlight.suppressesRelock, isFalse);
      SystemUiFlight.end();
      expect(SystemUiFlight.inFlight, isFalse);
    });
  });

  group('verification iteration 1 — source pins', () {
    // These pin WIRING contracts in files a Dart unit test
    // cannot execute (the shell's stop cascade, the native
    // notification builder). The defects they guard were
    // wiring defects: the right call reaching the wrong
    // entry point.
    String read(String path) => File(path).readAsStringSync();

    test('V-1: the stop cascade cannot cancel a donor start', () {
      final bootstrap = read('lib/ui/ember/mozilla_bootstrap.dart');
      expect(bootstrap, contains('void cancelFromCascade(String? fromEngine)'));
      // Iteration 2: the exemption is keyed to the SOURCE —
      // only the donor engine's own cascade is exempt; a
      // cascade from any other engine (an auto-reconnect, a
      // page-direct connect during a standalone Prepare)
      // still cancels.
      expect(bootstrap, contains('fromEngine == donor'));
      expect(bootstrap, contains('_startingDonor = true;'));
      expect(bootstrap, contains('_startingDonor = false;'));
      final shell = read('lib/ui/ember/ember_shell.dart');
      final start = shell.indexOf('Future<void> _stopMozilla({String? cascadeFrom})');
      expect(start, greaterThan(0));
      final body = shell.substring(start, shell.indexOf('\n  }', start));
      expect(body, contains('_bootstrap.cancelFromCascade(cascadeFrom);'));
      expect(body, isNot(contains('_bootstrap.cancel();')));
      expect(shell, contains("_stopMozilla(cascadeFrom: 'v2ray')"));
      expect(shell, contains("_stopMozilla(cascadeFrom: 'psiphon')"));
      expect(shell, contains("_stopMozilla(cascadeFrom: 'warp')"));
      // The genuine stop paths keep their direct cancel():
      // the chip switch and the mode-0 disconnect.
      expect(shell, contains('if (m != 0) _bootstrap.cancel();'));
      final dm = shell.indexOf('Future<void> _disconnectMode(int m)');
      final dmBody = shell.substring(dm, shell.indexOf('case 1:', dm));
      expect(dmBody, contains('_bootstrap.cancel();'));
    });

    test('V-3: the updater registers proxy credentials when demanded', () {
      final updater = read('lib/ui/ember/ember_updater.dart');
      expect(updater, contains('localProxyCredentialsResolver'));
      expect(updater, contains('addProxyCredentials'));
      final shell = read('lib/ui/ember/ember_shell.dart');
      expect(shell, contains('localProxyCredentialsResolver = ()'));
    });

    test('F-A2: deleteProfile guards the seamless-switch target', () {
      final xray = read('lib/xray/xray_controller.dart');
      final guard = xray.indexOf('Future<void> deleteProfile(Profile p)');
      expect(guard, greaterThan(0));
      final body = xray.substring(guard, xray.indexOf('profiles.removeWhere', guard));
      expect(body, contains('switchingProfileId == p.id'));
      expect(body, contains('_connectingProfileId == p.id'));
    });

    test('F-A3: the chain-exit deferral is consumed at true session ends',
        () {
      final xray = read('lib/xray/xray_controller.dart');
      // Build 2098: exactly one consumption call site (in
      // disconnect()). Build 2116 (B13-1, 2098 residual):
      // deliberate re-point — two more TRUE session ends
      // bypassed disconnect() and left the deferral pending
      // into the next session: an unexpected drop the
      // controller will not reconnect (both of its terminal
      // branches), and the auto-reconnect budget running
      // out. Four call sites now: disconnect's guarded one,
      // the drop's two, the retry budget's one — and still
      // nowhere else: a notice-only hand-over keeps the
      // session (and the deferral) alive, and internal stops
      // pass consumeChainExit: false.
      expect('_consumePendingChainExit();'.allMatches(xray).length, 4);
      final dc = xray.indexOf('Future<void> disconnect(');
      expect(dc, greaterThan(0));
      final window = xray.substring(dc, dc + 6000);
      expect(window, contains('_consumePendingChainExit();'));
      final drop = xray.indexOf('void _onUnexpectedDrop(');
      expect(drop, greaterThan(0));
      expect(
        xray.substring(drop, drop + 6000),
        contains('_consumePendingChainExit();'),
      );
      final retry = xray.indexOf('void _noteRetryFailed()');
      expect(retry, greaterThan(0));
      expect(
        xray.substring(retry, retry + 2000),
        contains('_consumePendingChainExit();'),
      );
      // Iteration 2: the WireGuard peer walk's internal
      // reset stop must not spend the deferral.
      expect(xray, contains('disconnect(consumeChainExit: false)'));
      expect(xray, contains('if (consumeChainExit) _consumePendingChainExit();'));
    });

    test('I2-A1: a mid-rotate disconnect aborts the switch', () {
      final xray = read('lib/xray/xray_controller.dart');
      final sw = xray.indexOf('Future<bool> switchServer(Profile next)');
      expect(sw, greaterThan(0));
      // PIN UPDATED by build 2149 (audit A43-04): the
      // rollback snapshot + closure lengthened switchServer
      // past the old 5000-char window; the pinned ORDER
      // (rotate -> gen check -> id writes) is unchanged.
      // The window now runs to the next method.
      final fnEnd = xray.indexOf('\n  Future<', sw + 10);
      final body = xray.substring(sw, fnEnd < 0 ? sw + 14000 : fnEnd);
      // The generation is re-checked after the rotate,
      // before the new profile's ids are written, and a
      // core the rotate respawned for a dead session is
      // stopped again (unless a connect superseded).
      expect(body, contains('if (!connecting) await _stopTunnel();'));
      final rotateAt = body.indexOf('XrayPlatform.rotateConfig');
      final checkAt = body.indexOf('if (!connecting) await _stopTunnel();');
      final idsAt = body.indexOf('selectedProfileId = next.id;');
      expect(rotateAt, lessThan(checkAt));
      expect(checkAt, lessThan(idsAt));
    });

    test('F1/F2: the scan page guards completions and re-entry', () {
      final page = read('lib/ui/ember/wg_scan_page.dart');
      expect(page, contains('int _scanGen = 0;'));
      expect(page, contains('gen != _scanGen'));
      expect(page, contains('if (_scanning || _connecting || _sessionBusy) return;'));
      // Iteration 2: progress is generation-guarded too,
      // and the page listens to the controller (a session
      // arriving mid-scan cancels it).
      expect(page, contains('gen == _scanGen'));
      expect(page, contains('addListener(_onXrayChanged)'));
      final probe = read('lib/xray/wg_probe.dart');
      expect(probe, contains('if (_cancelled) return null;'));
    });

    test('F5: only the busy guard says "disconnect before scanning"', () {
      final pages = read('lib/ui/ember/aether_pages.dart');
      expect(pages, contains("e.message =="));
      expect(pages, contains("'disconnect before scanning'"));
      final ctrl = read('lib/aether/aether_controller.dart');
      expect(ctrl, contains("throw StateError('disconnect before scanning')"));
    });

    test('V-2: a locked Resume opens the app, never the tunnel', () {
      final svc = read(
        'android/app/src/main/kotlin/com/ralysnd/ember/XrayVpnService.kt',
      );
      expect(
        svc,
        contains(
          'val resumeAction = if (ConnectWidget.appLockEnabled(this)) open else resume',
        ),
      );
      // The service-side gate remains as the backstop.
      expect(svc, contains('if (ConnectWidget.appLockEnabled(this)) return'));
      // Iteration 2: a lock toggled MID-PAUSE re-posts the
      // paused notification so its Resume action matches
      // the new lock state (nothing else rebuilds it while
      // paused — the speed-line refresh early-returns).
      expect(svc, contains('lockMarkerListener'));
      expect(svc, contains('registerOnSharedPreferenceChangeListener'));
      expect(svc, contains('unregisterOnSharedPreferenceChangeListener'));
    });
  });

}
// ---------------------------------------------------------------------
// Test-side Noise helpers (the responder implementation).
// These mirror the transcript steps, using wg_probe's
// vector-pinned primitives and PointyCastle's AEAD.

const _wgConstruction = 'Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s';
final _wgId = utf8.encode('WireGuard v1 zx2c4 Jason@zx2c4.com');

Uint8List _hmac(List<int> key, List<int> data) => hmacBlake2s(key, data);

(Uint8List, Uint8List) _kdf2(Uint8List chain, List<int> input) {
  final prk = _hmac(chain, input);
  final t1 = _hmac(prk, const [1]);
  final t2 = _hmac(prk, [...t1, 2]);
  return (t1, t2);
}

Uint8List _kdf1(Uint8List chain, List<int> input) =>
    _hmac(_hmac(chain, input), const [1]);

(Uint8List, Uint8List, Uint8List) _kdf3(Uint8List chain, List<int> input) {
  final prk = _hmac(chain, input);
  final t1 = _hmac(prk, const [1]);
  final t2 = _hmac(prk, [...t1, 2]);
  final t3 = _hmac(prk, [...t2, 3]);
  return (t1, t2, t3);
}

Uint8List _seal(List<int> key, List<int> plain, List<int> aad) {
  final cipher = pc.ChaCha20Poly1305(pc.ChaCha7539Engine(), pc.Poly1305());
  cipher.init(
    true,
    pc.AEADParameters(
      pc.KeyParameter(Uint8List.fromList(key)),
      128,
      Uint8List(12),
      Uint8List.fromList(aad),
    ),
  );
  // processBytes + doFinal, the pattern wg_probe's own
  // helpers use — plain process() does not finalize this
  // AEAD in PointyCastle and returns a zero buffer.
  final out = Uint8List(plain.length + 16);
  var len = cipher.processBytes(
    Uint8List.fromList(plain),
    0,
    plain.length,
    out,
    0,
  );
  len += cipher.doFinal(out, len);
  return Uint8List.sublistView(out, 0, len);
}

Uint8List? _open(List<int> key, List<int> sealed, List<int> aad) {
  final cipher = pc.ChaCha20Poly1305(pc.ChaCha7539Engine(), pc.Poly1305());
  cipher.init(
    false,
    pc.AEADParameters(
      pc.KeyParameter(Uint8List.fromList(key)),
      128,
      Uint8List(12),
      Uint8List.fromList(aad),
    ),
  );
  final out = Uint8List(sealed.length);
  try {
    var len = cipher.processBytes(
      Uint8List.fromList(sealed),
      0,
      sealed.length,
      out,
      0,
    );
    len += cipher.doFinal(out, len);
    return Uint8List.sublistView(out, 0, len);
  } catch (_) {
    return null;
  }
}


// ---------------------------------------------------------------------
// Shared test plumbing (build 2098 part 2).

void _mockAndroidChannel(
  Map<String, Object? Function(MethodCall)> handlers,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        final h = handlers[call.method];
        if (h != null) return h(call);
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
  });
}

/// A scripted HttpClient for the updater tests: records
/// whether a proxy was assigned and answers through
/// [handler] (or throws from it).
class _FakeHttpClient extends Fake implements HttpClient {
  _FakeHttpClient({required this.handler, this.onProxySet});

  final Future<_FakeResponse> Function() handler;
  final void Function()? onProxySet;

  @override
  set findProxy(String Function(Uri)? f) {
    if (f != null) onProxySet?.call();
  }

  @override
  set connectionTimeout(Duration? d) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpRequest(handler);

  @override
  void close({bool force = false}) {}
}

class _FakeHttpRequest extends Fake implements HttpClientRequest {
  _FakeHttpRequest(this.handler);

  final Future<_FakeResponse> Function() handler;

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  Future<HttpClientResponse> close() => handler();
}

class _FakeHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

/// A response that is also its own byte stream.
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse._(this._stream, this.statusCode);

  factory _FakeResponse.ok(List<int> bytes) =>
      _FakeResponse._(Stream.value(bytes), 200);

  factory _FakeResponse.silent() =>
      _FakeResponse._(StreamController<List<int>>().stream, 200);

  final Stream<List<int>> _stream;

  @override
  final int statusCode;

  @override
  int get contentLength => -1;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
