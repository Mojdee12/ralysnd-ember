// Build 2108 — the Block QUIC toggle (feature-watch 2026-11-18,
// DPIMech 0.3.0). Pins:
//  - the builder: with the toggle ON the tunnel config carries
//    exactly one UDP/443 → block routing rule, placed after the
//    DNS-module rule (so the core's own DNS queries, including
//    DoQ, still reach the proxy) and before every preset/custom
//    rule (so no preset can route QUIC around the block); with
//    the toggle OFF the generated config is byte-identical to a
//    build with the toggle explicitly off, and carries no QUIC
//    rule at all — 2107's shape;
//  - the settings gate: blockQuic defaults OFF, persists
//    through JSON (which is also the backup path —
//    _buildStoreDoc carries settings.toJson()), and a pre-2108
//    store keeps it off;
//  - the delay-test config is untouched by the toggle (it
//    carries no routing section at all, 2103-L6);
//  - sidecar-served profiles get the rule too: their traffic
//    still enters via the Xray inbounds, so the routing table
//    applies — while standalone Mozilla/WG/WARP/Psiphon/
//    Lantern/OpenVPN sessions never build an Xray config;
//  - the widget: the V2Ray section shows the "Block QUIC" row
//    and its toggle flips the setting and persists.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/lantern/lantern_controller.dart';
import 'package:firefox_vpn/openvpn/openvpn_controller.dart';
import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

List<Map<String, dynamic>> rulesOf(Map<String, dynamic> config) =>
    (config['routing']['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> outboundByTag(Map<String, dynamic> config, String tag) =>
    (config['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['tag'] == tag);

Profile _profile() => Profile(
  id: 'quic-test',
  name: 'QUIC test',
  protocol: Protocol.vless,
  address: 'nl1.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-0000-0000-000000000000',
  network: 'tcp',
  security: 'tls',
  sni: 'nl1.example.net',
);

/// The UDP/443 → block rules in [rules] (at most one is ever emitted).
List<Map<String, dynamic>> _quicBlockRules(
  List<Map<String, dynamic>> rules,
) => rules
    .where(
      (r) =>
          r['port'] == '443' &&
          r['network'] == 'udp' &&
          r['outboundTag'] == 'block',
    )
    .toList();

/// Pumps EmberSettings in V2Ray mode (1) with a fresh controller.
/// (Same harness as build2062's LAN-sharing widget tests.)
Future<XrayController> pumpSettings(WidgetTester tester) async {
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
  final settings = AppSettings()..emberMode = 1;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: EmberSettings(
          core: core,
          xray: xray,
          psiphon: psiphon,
          lantern: lantern,
          openvpn: openvpn,
          settings: settings,
        ),
      ),
    ),
  );
  await tester.pump();
  return xray;
}

void main() {
  group('the builder — the QUIC block rule', () {
    test('OFF: no UDP/443 rule and the block outbound still exists', () {
      final config = decode(buildTunnelConfig(_profile(), XraySettings()));
      final rules = rulesOf(config);
      expect(_quicBlockRules(rules), isEmpty);
      // The rule's target is always there (it predates this
      // build — the custom-block-domains rule uses it too).
      final block = outboundByTag(config, 'block');
      expect(block['protocol'], 'blackhole');
    });

    test('OFF: byte-identical to an explicitly-off build', () {
      final a = buildTunnelConfig(_profile(), XraySettings());
      final b = buildTunnelConfig(
        _profile(),
        XraySettings()..blockQuic = false,
      );
      expect(a, b);
    });

    test('ON: exactly one UDP/443 → block rule, exact shape', () {
      final config = decode(
        buildTunnelConfig(_profile(), XraySettings()..blockQuic = true),
      );
      final rules = rulesOf(config);
      final found = _quicBlockRules(rules);
      expect(found, hasLength(1));
      expect(found.single, {
        'type': 'field',
        'port': '443',
        'network': 'udp',
        'outboundTag': 'block',
      });
    });

    test('ON: placed before presets and custom lists, dns-module last',
        () {
      final s = XraySettings()
        ..blockQuic = true
        ..routingPreset = RoutingPreset.bypassIran
        ..customBlockDomains = ['ads.example.com'];
      final rules = rulesOf(decode(buildTunnelConfig(_profile(), s)));
      final blockAt = rules.indexWhere(
        (r) => r['port'] == '443' && r['outboundTag'] == 'block',
      );
      final dnsModuleAt = rules.indexWhere(
        (r) =>
            (r['inboundTag'] as List?)?.contains('dns-module') == true &&
            r['outboundTag'] == 'proxy',
      );
      final port53At = rules.indexWhere(
        (r) => r['port'] == '53' && r['outboundTag'] == 'dns-out',
      );
      final domesticAt = rules.indexWhere(
        (r) =>
            (r['inboundTag'] as List?)?.contains('domestic-dns') == true &&
            r['outboundTag'] == 'direct',
      );
      final iranAt = rules.indexWhere(
        (r) => (r['ip'] as List?)?.contains('geoip:ir') == true,
      );
      final customAt = rules.indexWhere(
        (r) => (r['domain'] as List?)?.contains('ads.example.com') == true,
      );
      // Build 2113 order: [domestic-dns→direct (the bypass
      // preset's direct domains exist, so it leads)],
      // [Block QUIC], [custom lists], [presets],
      // [dns-module→proxy LAST]. The port-53 rule exists
      // only with fakeDNS on — it is absent here.
      expect(domesticAt, isNonNegative);
      expect(dnsModuleAt, isNonNegative);
      expect(port53At, -1);
      expect(iranAt, isNonNegative);
      expect(customAt, isNonNegative);
      expect(blockAt, greaterThan(domesticAt));
      expect(blockAt, lessThan(iranAt));
      expect(blockAt, lessThan(customAt));
      expect(blockAt, lessThan(dnsModuleAt));
      expect(dnsModuleAt, rules.length - 1);
    });

    test('ON with DoQ: dns-module is last and DoQ still survives',
        () {
      final s = XraySettings()
        ..blockQuic = true
        ..remoteDnsProto = 'doq';
      final config = decode(buildTunnelConfig(_profile(), s));
      final rules = rulesOf(config);
      final blockAt = rules.indexWhere(
        (r) => r['port'] == '443' && r['outboundTag'] == 'block',
      );
      final dnsModuleAt = rules.indexWhere(
        (r) =>
            (r['inboundTag'] as List?)?.contains('dns-module') == true &&
            r['outboundTag'] == 'proxy',
      );
      // Build 2113: the dns-module rule is LAST now, so the
      // old "module rule leads" safety argument is gone.
      // DoQ survives for a different reason: the block rule
      // matches UDP/443 only, while the module's tunneled
      // upstreams are DoH over TCP/443, plain DNS on UDP or
      // TCP/53, or DoT on TCP/853 — and DoQ itself rides
      // quic+local, a local dial routing never sees. The
      // DoQ primary still emits, unchanged.
      expect(dnsModuleAt, greaterThanOrEqualTo(0));
      expect(dnsModuleAt, rules.length - 1);
      expect(blockAt, lessThan(dnsModuleAt));
      expect(rules[blockAt], {
        'type': 'field',
        'port': '443',
        'network': 'udp',
        'outboundTag': 'block',
      });
      expect((config['dns'] as Map)['servers'], [
        'quic+local://one.one.one.one',
      ]);
    });

    test('the delay-test config carries no routing section, on or off',
        () {
      for (final on in [false, true]) {
        final testConfig = decode(
          buildTestConfig(_profile(), XraySettings()..blockQuic = on),
        );
        expect(testConfig.containsKey('routing'), isFalse);
      }
    });

    test('a sidecar-served profile gets the rule too (same Xray inbounds)',
        () {
      // Sidecar protocols (TUIC/Mieru/Snell/NaiveProxy) are
      // dialed through a sidecar SOCKS outbound, but their
      // traffic still enters via the Xray core's inbounds, so
      // the routing table — and this rule — still applies.
      // Standalone Mozilla/WG/WARP/Psiphon/Lantern/OpenVPN
      // sessions never build an Xray config at all, so the
      // toggle cannot touch them; that is a structural fact,
      // not a testable branch of this builder.
      const sidecarPort = 20850;
      final on = decode(
        buildTunnelConfig(
          _profile(),
          XraySettings()..blockQuic = true,
          sidecarSocksPort: sidecarPort,
        ),
      );
      expect(_quicBlockRules(rulesOf(on)), hasLength(1));
      final off = decode(
        buildTunnelConfig(
          _profile(),
          XraySettings(),
          sidecarSocksPort: sidecarPort,
        ),
      );
      expect(_quicBlockRules(rulesOf(off)), isEmpty);
    });
  });

  group('the settings gate', () {
    test('blockQuic defaults OFF and persists', () {
      final s = XraySettings();
      expect(s.blockQuic, isFalse);
      s.blockQuic = true;
      final restored = XraySettings.fromJson(s.toJson());
      expect(restored.blockQuic, isTrue);
      // The key rides settings.toJson(), which is what the
      // store doc and the backup export carry.
      expect(s.toJson(), containsPair('blockQuic', true));
    });

    test('a pre-2108 settings document keeps QUIC unblocked', () {
      final doc = XraySettings().toJson()..remove('blockQuic');
      expect(XraySettings.fromJson(doc).blockQuic, isFalse);
    });

    test('a corrupt stored value cannot turn the block on by accident',
        () {
      final doc = XraySettings().toJson()..['blockQuic'] = 'yes';
      expect(XraySettings.fromJson(doc).blockQuic, isFalse);
    });
  });

  group('the widget — the Block QUIC row', () {
    // Build 2116 (B13-10, 2108-L2): deliberate re-point —
    // the row's label/subtitle were corrected to name what
    // the rule does (it drops ALL UDP/443, not only QUIC).
    // The toggle, placement and persistence are unchanged.
    testWidgets('row renders with its honest subtitle', (tester) async {
      final xray = await pumpSettings(tester);
      expect(xray.settings.blockQuic, isFalse);
      await tester.ensureVisible(find.text('Block QUIC (all UDP/443)'));
      await tester.pump();
      expect(find.text('Block QUIC (all UDP/443)'), findsOneWidget);
      expect(
        find.text(
          // Build 2125 re-point (A25-35): the subtitle now
          // states its scope — V2Ray sessions only, and
          // DNS-over-QUIC is not covered.
          'Drops every UDP packet to port 443, QUIC or not, so '
          'apps fall back to TCP. V2Ray sessions only — it '
          'does not cover DNS-over-QUIC, which resolves on '
          'the local endpoint (build 2125, audit A25-35).',
        ),
        findsOneWidget,
      );
      // The row sits directly after Sniff QUIC, in the same
      // QUIC family of the V2Ray section.
      expect(find.text('Sniff QUIC'), findsOneWidget);
    });

    testWidgets('tapping the toggle flips the setting and persists', (
      tester,
    ) async {
      final xray = await pumpSettings(tester);
      await tester.ensureVisible(find.text('Block QUIC (all UDP/443)'));
      await tester.pump();
      final row = find.ancestor(
        of: find.text('Block QUIC (all UDP/443)'),
        matching: find.byType(MapSettingRow),
      );
      final toggle = find.descendant(
        of: row,
        matching: find.byType(EmberToggle),
      );
      expect(toggle, findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect(xray.settings.blockQuic, isTrue);
      expect(
        XraySettings.fromJson(xray.settings.toJson()).blockQuic,
        isTrue,
      );
      await tester.tap(toggle);
      await tester.pump();
      expect(xray.settings.blockQuic, isFalse);
    });

    test('the row is present in source beside Sniff QUIC', () {
      // A source pin against silent removal: the widget test
      // above proves the row renders; this pins the placement.
      final src = File(
        'lib/ui/ember/ember_settings.dart',
      ).readAsStringSync();
      final sniffAt = src.indexOf("label: 'Sniff QUIC'");
      final blockAt = src.indexOf("label: 'Block QUIC (all UDP/443)'");
      expect(sniffAt, isNonNegative);
      expect(blockAt, greaterThan(sniffAt));
    });
  });
}
