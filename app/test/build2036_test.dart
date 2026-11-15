/// Build 2036 gates, host side: Hysteria2 congestion-control
/// choice (Iran-priority queue 2d) — per-profile BBR
/// standard / conservative / aggressive + Reno, wired to the
/// patched core's quicParams (streamSettings.finalmask).
/// The core side was verified in the bundled Xray-core
/// v26.10.29 source before building: QuicParamsConfig accepts
/// congestion "reno"/"bbr" and bbrProfile
/// "conservative"/"standard"/"aggressive", and the hysteria
/// dialer applies UseBBR with the profile (or the transport
/// default for "reno"); invalid values fail the config build.
/// Live `xray run -test` results for every shipped variant are
/// recorded in BUILD-LOG-2.md (build 2036) — these tests pin
/// the DART side of that contract.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile hy2({String hyCongestion = ''}) => Profile(
  id: 'h1',
  protocol: Protocol.hysteria2,
  name: 'hy2',
  address: 'hy.example.com',
  port: 443,
  uuidOrPassword: 'pw',
  sni: 'hy.example.com',
  hyCongestion: hyCongestion,
);

Map<String, dynamic>? finalmaskOf(Profile p) {
  final out = buildOutbound(p, XraySettings())!;
  final stream = out['streamSettings'] as Map<String, dynamic>;
  return stream['finalmask'] as Map<String, dynamic>?;
}

void main() {
  group('Hysteria2 congestion control (queue 2d)', () {
    test('model: default is empty, and old stored JSON upgrades to it', () {
      expect(Profile(id: 'x', protocol: Protocol.hysteria2).hyCongestion, '');
      final old = Profile.fromJson({
        'id': 'x',
        'protocol': 'hysteria2',
      });
      expect(old.hyCongestion, '');
    });

    test('model: every choice round-trips through JSON storage', () {
      for (final choice in [
        '',
        'reno',
        'bbr-standard',
        'bbr-conservative',
        'bbr-aggressive',
      ]) {
        final p = hy2(hyCongestion: choice);
        expect(Profile.fromJson(p.toJson()).hyCongestion, choice);
      }
    });

    test('builder: default emits no finalmask at all (config unchanged)', () {
      expect(finalmaskOf(hy2()), isNull);
    });

    test('builder: each choice emits exactly its quicParams', () {
      expect(finalmaskOf(hy2(hyCongestion: 'reno')), {
        'quicParams': {'congestion': 'reno'},
      });
      expect(finalmaskOf(hy2(hyCongestion: 'bbr-standard')), {
        'quicParams': {'congestion': 'bbr', 'bbrProfile': 'standard'},
      });
      expect(finalmaskOf(hy2(hyCongestion: 'bbr-conservative')), {
        'quicParams': {'congestion': 'bbr', 'bbrProfile': 'conservative'},
      });
      expect(finalmaskOf(hy2(hyCongestion: 'bbr-aggressive')), {
        'quicParams': {'congestion': 'bbr', 'bbrProfile': 'aggressive'},
      });
    });

    test('builder: salamander obfs and congestion merge into one finalmask', () {
      final p = hy2(hyCongestion: 'bbr-aggressive')
        ..obfs = 'salamander'
        ..obfsPassword = 'salapw';
      final fm = finalmaskOf(p)!;
      final udp = fm['udp'] as List;
      expect(udp.single['type'], 'salamander');
      expect(
        (udp.single['settings'] as Map)['password'],
        'salapw',
      );
      expect(fm['quicParams'], {
        'congestion': 'bbr',
        'bbrProfile': 'aggressive',
      });
    });

    test('builder: an unknown stored value is dropped, never sent', () {
      final p = hy2(hyCongestion: 'brutal');
      expect(finalmaskOf(p), isNull);
      final q = hy2(hyCongestion: 'BBR');
      expect(finalmaskOf(q), isNull);
    });

    test('builder: the choice never leaks onto other protocols', () {
      final p = Profile(
        id: 'v1',
        protocol: Protocol.vless,
        name: 'v',
        address: 'v.example.com',
        port: 443,
        uuidOrPassword: '00000000-0000-4000-8000-000000000000',
        security: 'tls',
        sni: 'v.example.com',
        hyCongestion: 'bbr-aggressive',
      );
      final out = buildOutbound(p, XraySettings())!;
      final stream = out['streamSettings'] as Map<String, dynamic>;
      expect(stream.containsKey('finalmask'), isFalse);
    });

    test('link: congestion round-trips through share and import', () {
      final p = parseLink(
        'hysteria2://pw@hy.example.com:443?congestion=bbr-conservative#h',
      );
      expect(p!.hyCongestion, 'bbr-conservative');
      final back = parseLink(profileToLink(p));
      expect(back!.hyCongestion, 'bbr-conservative');
      expect(profileToLink(hy2()), isNot(contains('congestion')));
    });

    test('link: an unknown congestion value imports as the default', () {
      final p = parseLink(
        'hysteria2://pw@hy.example.com:443?congestion=brutal#h',
      );
      expect(p!.hyCongestion, '');
      expect(profileToLink(p), isNot(contains('congestion')));
    });

    test('full tunnel config carries the choice where the core reads it', () {
      final json = buildTunnelConfig(
        hy2(hyCongestion: 'bbr-conservative'),
        XraySettings(),
      );
      final cfg = decode(json);
      final outbounds = cfg['outbounds'] as List;
      final proxy = outbounds.first as Map<String, dynamic>;
      final stream = proxy['streamSettings'] as Map<String, dynamic>;
      expect(
        (stream['finalmask'] as Map)['quicParams'],
        {'congestion': 'bbr', 'bbrProfile': 'conservative'},
      );
    });
  });
}
