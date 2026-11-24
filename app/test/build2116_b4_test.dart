/// Build 2116, batch B4 — the sing-box sidecar rows.
///
/// Step 0 re-verified the audit's summary claims firsthand
/// (progress file): C2-01/C2-02/C2-03 VOID, C2-04
/// contradicted. Three more summary rows turned out to be
/// ALREADY wired in the base tree — naive username
/// (C2-14), TUIC alpn (C2-18) and Snell obfs — and are
/// pinned here so they cannot silently regress. The real
/// fixes: ECH emission (G-19), TUIC extras (G-21), TUIC
/// allow_insecure (S-01), NaiveProxy extra params (S-02)
/// and the log level following the setting (S-06).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> outboundOf(Map<String, dynamic> config) =>
    (config['outbounds'] as List).single as Map<String, dynamic>;

void main() {
  group('B4-2/B4-3 — TUIC extras + allow_insecure (G-21, S-01)', () {
    final p = parseLink(
      'tuic://uuid-1:pass@tuic.example:443'
      '?congestion_control=cubic&udp_relay_mode=quic'
      '&zero_rtt_handshake=1&heartbeat=10s&udp_over_stream=true'
      '&disable_sni=1&allow_insecure=1&alpn=h3,h2&sni=sni.example#T',
    )!;

    test('the parser carries all four extras + the flag', () {
      expect(p.zeroRttHandshake, isTrue);
      expect(p.tuicHeartbeat, '10s');
      expect(p.udpOverStream, isTrue);
      expect(p.disableSni, isTrue);
      expect(p.tuicAllowInsecure, isTrue);
    });

    test('the fields survive the profile JSON round-trip', () {
      final back = Profile.fromJson(p.toJson());
      expect(back.zeroRttHandshake, isTrue);
      expect(back.tuicHeartbeat, '10s');
      expect(back.udpOverStream, isTrue);
      expect(back.disableSni, isTrue);
      expect(back.tuicAllowInsecure, isTrue);
    });

    test('the outbound emits them; tls carries insecure + disable_sni', () {
      final out = outboundOf(buildSingBoxConfig(p));
      expect(out['zero_rtt_handshake'], isTrue);
      expect(out['heartbeat'], '10s');
      expect(out['udp_over_stream'], isTrue);
      final tls = out['tls'] as Map<String, dynamic>;
      expect(tls['insecure'], isTrue);
      expect(tls['disable_sni'], isTrue);
    });

    test('a plain TUIC link emits none of them', () {
      final plain = parseLink('tuic://uuid-1@tuic.example:443#T')!;
      expect(plain.tuicAllowInsecure, isFalse);
      final out = outboundOf(buildSingBoxConfig(plain));
      expect(out.containsKey('zero_rtt_handshake'), isFalse);
      expect(out.containsKey('heartbeat'), isFalse);
      expect(out.containsKey('udp_over_stream'), isFalse);
      final tls = out['tls'] as Map<String, dynamic>;
      expect(tls.containsKey('insecure'), isFalse);
      expect(tls.containsKey('disable_sni'), isFalse);
    });
  });

  group('B4-6 (already in base) — TUIC alpn (C2-18)', () {
    test('the link alpn wins; h3 is only the no-alpn default', () {
      final withAlpn = parseLink(
        'tuic://uuid-1@tuic.example:443?alpn=h3,h2#T',
      )!;
      final tls = outboundOf(buildSingBoxConfig(withAlpn))['tls'] as Map;
      expect(tls['alpn'], ['h3', 'h2']);
      final bare = parseLink('tuic://uuid-1@tuic.example:443#T')!;
      final tls2 = outboundOf(buildSingBoxConfig(bare))['tls'] as Map;
      expect(tls2['alpn'], ['h3']);
    });
  });

  group('B4-1 — sidecar ECH (G-19)', () {
    test('a base64 ECHConfigList is emitted as ech.config', () {
      final p = parseLink(
        'tuic://uuid-1@tuic.example:443?ech=ABCdef123%2B%2Fxyz%3D#T',
      )!;
      expect(p.echConfigList, isNotEmpty);
      final tls = outboundOf(buildSingBoxConfig(p))['tls'] as Map;
      expect(tls['ech'], {
        'enabled': true,
        'config': [p.echConfigList],
      });
    });

    test('the query form stays Xray-only (no ech emitted)', () {
      final p = Profile(
        id: 'x',
        protocol: Protocol.tuic,
        address: 'tuic.example',
        port: 443,
        uuidOrPassword: 'uuid-1',
      )..echConfigList = 'cloudflare-ech.com+udp://1.1.1.1';
      final tls = outboundOf(buildSingBoxConfig(p))['tls'] as Map;
      expect(tls.containsKey('ech'), isFalse);
    });
  });

  group('B4-5 (already in base) — Naive username (C2-14)', () {
    test('user:pass@ reaches the outbound as username + password', () {
      final p = parseLink(
        'naive+https://alice:secret@naive.example:443#N',
      )!;
      expect(p.username, 'alice');
      final out = outboundOf(buildSingBoxConfig(p));
      expect(out['username'], 'alice');
      expect(out['password'], 'secret');
    });
  });

  group('B4-4 — NaiveProxy extra params (S-02)', () {
    final p = parseLink(
      'naive+https://alice:secret@naive.example:443'
      '?padding=true&insecure_concurrency=4&quic=1&sni=sni.example#N',
    )!;

    test('unconsumed params are stored verbatim at import', () {
      expect(p.naiveExtras['padding'], 'true');
      expect(p.naiveExtras['insecure_concurrency'], '4');
      expect(p.naiveExtras['quic'], '1');
      expect(p.naiveExtras.containsKey('sni'), isFalse);
      final back = Profile.fromJson(p.toJson());
      expect(back.naiveExtras['padding'], 'true');
    });

    test('the supported subset is emitted; padding is journalled', () {
      final out = outboundOf(buildSingBoxConfig(p));
      expect(out['insecure_concurrency'], 4);
      expect(out['quic'], isTrue);
      expect(out.containsKey('padding'), isFalse);
      expect(p.hasUnappliedNaivePadding, isTrue);
    });

    test('a bare naive link carries no extras', () {
      final bare = parseLink(
        'naive+https://alice:secret@naive.example:443#N',
      )!;
      expect(bare.naiveExtraParams, isEmpty);
      expect(bare.hasUnappliedNaivePadding, isFalse);
    });
  });

  group('B4-7 (already in base) — Snell obfs', () {
    test('obfs + obfs-host parse and emit', () {
      final p = parseLink(
        'snell://psk-key@snell.example:443?version=4&obfs=http&obfs-host=cdn.example#S',
      )!;
      expect(p.obfs, 'http');
      expect(p.obfsPassword, 'cdn.example');
      final out = outboundOf(buildSingBoxConfig(p));
      expect(out['obfs_mode'], 'http');
      expect(out['obfs_host'], 'cdn.example');
    });
  });

  group('B4-8 — sidecar log level follows the setting (S-06)', () {
    final p = parseLink('tuic://uuid-1@tuic.example:443#T')!;

    test('the mapping', () {
      expect(singBoxLogLevel('warning'), 'warn');
      expect(singBoxLogLevel('warn'), 'warn');
      expect(singBoxLogLevel('debug'), 'debug');
      expect(singBoxLogLevel('info'), 'info');
      expect(singBoxLogLevel('error'), 'error');
      expect(singBoxLogLevel('bogus'), 'warn');
    });

    test('the config carries the mapped level; none disables', () {
      expect(buildSingBoxConfig(p)['log']['level'], 'warn');
      expect(buildSingBoxConfig(p, logLevel: 'debug')['log']['level'], 'debug');
      final none = buildSingBoxConfig(p, logLevel: 'none')['log'] as Map;
      expect(none['disabled'], isTrue);
      expect(none.containsKey('level'), isFalse);
    });
  });
}
