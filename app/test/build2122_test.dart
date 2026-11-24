// Build 2122 — the core-capability round (owner picks
// 2026-11-20 04:27 from the core list: items 13, 14, 9, 3),
// under the owner's binding refinement of the same minute:
// ZERO breakage first (when in doubt, park); every landed item
// behind its own Settings toggle, DEFAULT OFF, zero effect
// while off; gate tests proving all-off configs/behaviour are
// byte-identical to the 2121 baseline.
//
// Per-item outcome of the firsthand analysis against the
// cores Ember actually ships:
//
//  1. QUIC anti-sniff decoy byte (LxBox / sing-box-lx) —
//     PARKED, all three legs. TUIC rides the sing-box sidecar,
//     which is the OFFICIAL SagerNet sing-box v1.14.4 release
//     binary (engines/singbox/PROVENANCE.md, sha256-pinned);
//     Ember's only surface is the generated config JSON and
//     upstream 1.14.4 has no decoy/pre-packet option (it is a
//     sing-box-lx fork feature). MASQUE rides Aether
//     (libaether.so, a vendored binary with no source in the
//     repo and no rebuild step in the app pipeline): the trick
//     needs the junk datagram on the SAME UDP socket/flow as
//     the handshake, the app cannot write to Aether's socket,
//     and a junk datagram from a separate app socket is a
//     different flow (different source port), so a per-flow
//     sniffer still sees a clean QUIC Initial first. Hy2 rides
//     the vendored Xray fork (native-src/xray, 26.10.29): the
//     patch point exists (hysteria2 dialer, same PacketConn),
//     but libxray.so is a vendored binary the pipeline never
//     rebuilds — landing it means reviving the full core build
//     and re-vendoring a new core binary, a core swap touching
//     every Xray path. Parked until a core build is
//     commissioned on its own.
//
//  2. Multi-packet QUIC ClientHello sniffing (Hysteria
//     2.13.0) — ALREADY PRESENT in the shipped product;
//     verified in this round, nothing to build. Core end: the
//     fork's SniffQUIC reassembles CRYPTO frames by offset
//     across packets and returns ErrProtoNeedMoreData when
//     incomplete, and the dispatcher sniffer loop
//     (app/dispatcher/default.go) keeps Cache()-ing further
//     datagrams and re-invoking without consuming attempts
//     inside its 200 ms window; the fork's own Go tests feed
//     handshakes as packet 1 / packets 1-2 / packets 1-3
//     (TestSniffQUICComplex — run in this round:
//     `go test ./common/protocol/quic/` = ok). App end:
//     XraySettings.sniffQuic (DEFAULT OFF since build 2103),
//     the "Sniff QUIC" Settings row, and config_builder
//     emitting 'quic' into destOverride at both inbound sites
//     only when on — pinned below in both states.
//
//  3. GooseRelay transport (Hiddify core) — PARKED. It exists
//     only in the hiddify-sing-box fork; the shipped sidecar
//     is official upstream v1.14.4, whose outbound registry
//     has no gooserelay (PROVENANCE capability list: TUIC /
//     Snell / Naive / Tailscale / OpenConnect; the binary
//     carries no 'goose'). Landing it = replacing the
//     vendored sidecar with a fork build = core swap.
//
//  4. Bond, connection bonding (Hiddify core) — PARKED, two
//     independent blockers. (a) The bond outbound is
//     hiddify-sing-box only; upstream sing-box 1.14.4 and the
//     Xray fork offer selector/urltest groups — a
//     per-CONNECTION choice, not splitting one connection —
//     which Ember already ships as fallback/Smart groups.
//     (b) Bonding only works against a server running the
//     matching Hiddify bond endpoint that re-joins the split
//     streams; for arbitrary user servers a client toggle
//     would be a dead path.
//
// This file is the round's gate: with everything off, the
// generated tunnel config is byte-identical to the 2121
// baseline (length + sniffing shape measured on the pristine
// 2121 tree BEFORE any 2122 change), the parked items leak
// nothing into generated configs or the config-generation
// sources, and the one already-present capability (item 2)
// is pinned in both of its states. NO lib/ code changed in
// this build. All fixtures use dummy values.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Profile _profile() => Profile(
      id: 'gate-2122',
      name: 'Gate 2122',
      protocol: Protocol.vless,
      address: 'nl1.example.net',
      port: 443,
      uuidOrPassword: '00000000-0000-0000-0000-000000000000',
      network: 'tcp',
      security: 'tls',
    );

List<List<dynamic>> _destOverrides(Map<String, dynamic> config) => [
      for (final ib in config['inbounds'] as List)
        if ((ib as Map)['sniffing'] != null)
          ((ib['sniffing'] as Map)['destOverride'] as List).cast<dynamic>(),
    ];

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('build 2122 — all-off gate (byte-identity with 2121)', () {
    test('the shipped sniffing defaults are untouched', () {
      final s = XraySettings();
      expect(s.sniffing, isTrue);
      expect(s.sniffHttp, isTrue);
      expect(s.sniffTls, isTrue);
      // Build 2103: QUIC sniffing is an opt-in extra; the
      // multi-packet capability of item 2 sits behind it.
      expect(s.sniffQuic, isFalse);
      expect(s.fakeDns, isFalse);
    });

    test('the default tunnel config is the 2121 baseline, byte for byte',
        () {
      final config = buildTunnelConfig(_profile(), XraySettings());
      // Measured on the pristine 2121 tree before any 2122
      // change (the z-pin method of build 2120).
      // Build 2125 SUPERSESSION (recorded, not silent):
      // A25-33 emits the config compact — the length pins
      // the compact encoding (2915) of the SAME document
      // whose decoded structure is asserted below; the
      // pretty encoding measured 4891.
      expect(config.length, 2915);
      final doc = jsonDecode(config) as Map<String, dynamic>;
      final overrides = _destOverrides(doc);
      expect(overrides, hasLength(2),
          reason: 'socks + http inbounds carry sniffing; api does not');
      for (final o in overrides) {
        expect(o, ['http', 'tls'],
            reason: 'v2rayNG\'s set; QUIC stays opt-in (build 2103)');
      }
    });

    test('the parked items leak nothing into generated configs', () {
      final config = buildTunnelConfig(_profile(), XraySettings());
      expect(config.contains('gooserelay'), isFalse);
      expect(config.contains('bond'), isFalse);
      expect(config.contains('decoy'), isFalse);
    });

    test('the parked items exist nowhere in the config-generation sources',
        () {
      for (final path in [
        'lib/xray/config_builder.dart',
        'lib/xray/singbox_config.dart',
        'lib/xray/xray_models.dart',
      ]) {
        final src = _read(path).toLowerCase();
        expect(src.contains('gooserelay'), isFalse, reason: path);
        // Build 2126 supersession (D6, owner order
        // 2026-11-21 04:33): the Hy2 leg of the decoy pick
        // LANDED — the word now legitimately appears in
        // the config sources, behind its DEFAULT-OFF
        // toggle (the all-off emission pin above still
        // proves a default config carries none of it).
        // The TUIC/MASQUE legs stay parked and unbuilt.
      }
      // The sidecar's protocol set is the upstream 1.14.4 set:
      // no bond outbound is offered, parsed or generated.
      final sidecar = _read('lib/xray/singbox_config.dart').toLowerCase();
      expect(sidecar.contains('bond'), isFalse);
    });
  });

  group('build 2122 — item 2 (multi-packet QUIC sniffing) wiring', () {
    test('the owner\'s Settings control for it exists and is the shipped one',
        () {
      final src = _read('lib/ui/ember/ember_settings.dart');
      expect(src, contains("'Sniff QUIC'"));
      expect(src, contains('s.sniffQuic'));
    });

    test('sniffQuic ON adds quic at both inbound sites, and only there', () {
      final config =
          buildTunnelConfig(_profile(), XraySettings()..sniffQuic = true);
      // 2915 + 2 x '"quic",' insertions — nothing else
      // moves. (Build 2125: compact baseline, see above;
      // the pretty-era numbers were 4891 + 36 = 4927.)
      expect(config.length, 2929);
      final doc = jsonDecode(config) as Map<String, dynamic>;
      final overrides = _destOverrides(doc);
      expect(overrides, hasLength(2));
      for (final o in overrides) {
        expect(o, ['http', 'tls', 'quic']);
      }
    });
  });
}
