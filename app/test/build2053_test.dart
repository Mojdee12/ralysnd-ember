import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

/// Build 2053 — audit Batch 4 (Highs F-H4, F-H5, F-H6, F-H7).
///
/// Each finding was verified against the bundled core's own
/// source (toolchain/gopath module cache, xtls/xray-core
/// @v1.260327.1) before the fix, not taken on the audit's word:
/// - F-H4: app/dns/nameserver.go NewServer dispatches ONLY
///   `quic+local` (no `quic` case) — the old `quic://` form fell
///   through to a classic UDP server against a host literally
///   named `quic://…`.
/// - F-H5: infra/conf/transport_security.go TLSConfig has
///   `pinnedPeerCertSha256` and NO `pinSHA256` key.
/// - F-H6: infra/conf/transport_finalmask.go QuicParamsConfig
///   has `brutalUp`/`brutalDown` Bandwidth strings ("N mbps"),
///   and transport/internet/hysteria/dialer.go runs Brutal with
///   min(brutalUp, server-advertised down) under the DEFAULT
///   congestion too — no `force-brutal` needed.
/// - F-H7: parser/store/builder/codec all carried SOCKS
///   credentials; only the editor had no field for them.

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// Finds an editor field by its visible label (build 2056: the
/// editor's labels are wrapping Text widgets in the decoration's
/// `label` slot now, not `labelText` — the framework forbids
/// setting both, so the old labelText finder matches nothing).
Finder _field(String label) => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.label is Text &&
      (w.decoration!.label as Text).data == label,
);

Profile _vless() => Profile(
  id: 'v1',
  protocol: Protocol.vless,
  name: 'v',
  address: 'v.example.com',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: 'v.example.com',
);

List<dynamic> dnsServersOf(XraySettings s) {
  final cfg = decode(buildTunnelConfig(_vless(), s));
  return (cfg['dns'] as Map<String, dynamic>)['servers'] as List;
}

/// The nameserver schemes the bundled core's NewServer actually
/// dispatches (app/dns/nameserver.go) — anything else in a
/// generated DNS section is a silent misroute.
const _coreDnsSchemes = {'https', 'h2c', 'quic+local', 'tcp'};

String _schemeOf(String server) {
  final i = server.indexOf('://');
  if (i < 0) return '';
  return server.substring(0, i);
}

const _pin =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Profile _hy2({
  String tlsCertPin = '',
  String fingerprint = '',
  int upMbps = 0,
  int downMbps = 0,
  String hyCongestion = '',
}) => Profile(
  id: 'h1',
  protocol: Protocol.hysteria2,
  name: 'h',
  address: 'h.example.com',
  port: 443,
  uuidOrPassword: 'pw',
  security: 'tls',
  sni: 'h.example.com',
  tlsCertPin: tlsCertPin,
  fingerprint: fingerprint,
  upMbps: upMbps,
  downMbps: downMbps,
  hyCongestion: hyCongestion,
);

Map<String, dynamic> _hy2Stream(Profile p) {
  final out = buildOutbound(p, XraySettings())!;
  return out['streamSettings'] as Map<String, dynamic>;
}

void main() {
  group('F-H4 DoQ: the core dispatches only quic+local', () {
    test('doqFormOf emits quic+local for every provider', () {
      expect(doqFormOf('https://dns.google/dns-query'), 'quic+local://dns.google');
      expect(
        doqFormOf('https://cloudflare-dns.com/dns-query'),
        'quic+local://one.one.one.one',
      );
      expect(
        doqFormOf('https://dns.quad9.net/dns-query'),
        'quic+local://dns.quad9.net',
      );
      expect(
        doqFormOf('https://dns.adguard-dns.com/dns-query'),
        'quic+local://dns.adguard-dns.com',
      );
      expect(
        doqFormOf('https://dns.example.org/dns-query'),
        'quic+local://dns.example.org',
      );
    });

    test('no doqFormOf output starts with the undispatched quic://', () {
      for (final url in [
        'https://dns.google/dns-query',
        'https://cloudflare-dns.com/dns-query',
        'https://dns.quad9.net/dns-query',
        'https://dns.example.org/dns-query',
        'not-a-url',
      ]) {
        expect(doqFormOf(url), isNot(startsWith('quic://')));
      }
    });

    test('primaryResolver and group members follow the transport', () {
      // Build 2113: the default remote is v2rayNG's
      // Cloudflare DoH again, so its DoQ form is the mapped
      // one.one.one.one form; the mapping itself is unchanged.
      final s = XraySettings()..remoteDnsProto = 'doq';
      expect(primaryResolver(s), 'quic+local://one.one.one.one');
      expect(resolverUnderTransport('https://dns.google/dns-query', 'doq'),
          'quic+local://dns.google');
      expect(resolverUnderTransport('https://dns.google/dns-query', 'doh'),
          'https://dns.google/dns-query');
    });

    test('every emitted DNS server scheme is in the core dispatch set', () {
      // The core's NewServer switch: https, h2c, https+local,
      // h2c+local, quic+local, tcp, tcp+local, fakedns, and
      // bare IP literals (classic UDP). A generated section must
      // never contain a scheme outside that set — the 2032 bug
      // was exactly such a scheme, and xray run -test never
      // instantiates the DNS client, so only this test catches it.
      for (final proto in ['doh', 'doq', 'tcp']) {
        for (final group in [false, true]) {
          final s = XraySettings()
            ..remoteDnsProto = proto
            ..dnsGroup = group;
          for (final server in dnsServersOf(s)) {
            final raw = server as String;
            if (raw == 'fakedns') continue;
            final scheme = _schemeOf(raw);
            if (scheme.isEmpty) continue; // bare IP literal
            expect(
              _coreDnsSchemes.contains(scheme) ||
                  scheme.endsWith('+local'),
              isTrue,
              reason: 'proto=$proto group=$group server=$raw',
            );
            expect(raw, isNot(contains('quic://')));
          }
        }
      }
    });

    test('DoQ default shape: the mapped single entry, no TCP fallback (2101, 2113)',
        () {
      // Build 2049 kept a TCP fallback behind the DoQ primary;
      // build 2101 removes it (owner order 2026-11-18). Build
      // 2113: the default remote is the single Cloudflare DoH
      // entry again (the 2111 pair and its append are gone),
      // so the DoQ default is its one quic+local form — still
      // no TCP fallback.
      final doq = XraySettings()..remoteDnsProto = 'doq';
      expect(dnsServersOf(doq), [
        'quic+local://one.one.one.one',
      ]);
      final doqGroup = XraySettings()
        ..remoteDnsProto = 'doq'
        ..dnsGroup = true;
      expect(dnsServersOf(doqGroup), [
        'quic+local://one.one.one.one',
        'quic+local://dns.google',
        'quic+local://dns.quad9.net',
      ]);
    });
  });

  group('F-H5 Hy2 pin: pinnedPeerCertSha256, not pinSHA256', () {
    test('parse stores the pin in tlsCertPin, not fingerprint', () {
      final p = parseLink(
        'hysteria2://pw@h.example.com:443/?sni=h.example.com&pinSHA256=$_pin#h',
      )!;
      expect(p.protocol, Protocol.hysteria2);
      expect(p.tlsCertPin, _pin);
      expect(p.fingerprint, isEmpty);
    });

    test('builder emits pinnedPeerCertSha256 and no pinSHA256 key', () {
      final stream = _hy2Stream(_hy2(tlsCertPin: _pin));
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['pinnedPeerCertSha256'], _pin);
      expect(tls.containsKey('pinSHA256'), isFalse);
    });

    test('legacy fingerprint pin is still honoured at emit time', () {
      // Pre-2053 imports stored the pin in `fingerprint` — the
      // control must not be silently lost for profiles that
      // have never been re-edited.
      final stream = _hy2Stream(_hy2(fingerprint: _pin));
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['pinnedPeerCertSha256'], _pin);
      expect(tls.containsKey('pinSHA256'), isFalse);
    });

    test('an invalid pin is dropped, the profile still connects', () {
      final p = parseLink(
        'hysteria2://pw@h.example.com:443/?sni=h.example.com&pinSHA256=deadbeef#h',
      )!;
      expect(p.tlsCertPin, isEmpty);
      final tls =
          _hy2Stream(p)['tlsSettings'] as Map<String, dynamic>;
      expect(tls.containsKey('pinnedPeerCertSha256'), isFalse);
      expect(tls.containsKey('pinSHA256'), isFalse);
    });

    test('Hy2 tlsSettings keys are all core TLSConfig fields', () {
      // The schema cross-check for this finding's class: every
      // key the builder emits into tlsSettings must exist in the
      // core's TLSConfig json tags (transport_security.go).
      // `pinSHA256` is not one — that is the bug this test pins.
      const coreTlsKeys = {
        'serverName',
        'alpn',
        'pinnedPeerCertSha256',
        'echConfigList',
        'fingerprint',
        'cipherSuites',
        'allowInsecure', // core-side key; Ember never emits it
      };
      final tls =
          _hy2Stream(_hy2(tlsCertPin: _pin))['tlsSettings']
              as Map<String, dynamic>;
      for (final key in tls.keys) {
        expect(coreTlsKeys.contains(key), isTrue, reason: 'key=$key');
      }
      expect(tls.containsKey('allowInsecure'), isFalse);
    });

    test('round-trip parse -> share -> parse preserves the pin', () {
      final p = parseLink(
        'hysteria2://pw@h.example.com:443/?sni=h.example.com&pinSHA256=$_pin&up=100&down=200#h',
      )!;
      final again = parseLink(profileToLink(p))!;
      expect(again.tlsCertPin, _pin);
      expect(again.upMbps, 100);
      expect(again.downMbps, 200);
    });

    test('a user-added pin does not break refresh identity', () {
      final plain = parseLink(
        'hysteria2://pw@h.example.com:443/?sni=h.example.com#h',
      )!;
      final pinned = parseLink(
        'hysteria2://pw@h.example.com:443/?sni=h.example.com&pinSHA256=$_pin#h',
      )!;
      expect(profileIdentityLink(pinned), profileIdentityLink(plain));
    });
  });

  group('F-H6 Hy2 bandwidth: brutalUp/brutalDown reach the core', () {
    test('default congestion + bandwidth emits brutalUp/Down only', () {
      final stream = _hy2Stream(_hy2(upMbps: 100, downMbps: 200));
      final finalmask = stream['finalmask'] as Map<String, dynamic>;
      final qp = finalmask['quicParams'] as Map<String, dynamic>;
      expect(qp['brutalUp'], '100 mbps');
      expect(qp['brutalDown'], '200 mbps');
      expect(qp.containsKey('congestion'), isFalse);
    });

    test('bandwidth merges with an explicit congestion choice', () {
      final stream = _hy2Stream(
        _hy2(upMbps: 50, hyCongestion: 'bbr-standard'),
      );
      final qp =
          (stream['finalmask'] as Map<String, dynamic>)['quicParams']
              as Map<String, dynamic>;
      expect(qp['congestion'], 'bbr');
      expect(qp['bbrProfile'], 'standard');
      expect(qp['brutalUp'], '50 mbps');
      expect(qp.containsKey('brutalDown'), isFalse);
    });

    test('no bandwidth and default congestion emits no finalmask', () {
      final stream = _hy2Stream(_hy2());
      expect(stream.containsKey('finalmask'), isFalse);
    });

    test('zero or negative bandwidth is never emitted', () {
      final stream = _hy2Stream(_hy2(upMbps: -5, downMbps: 0));
      expect(stream.containsKey('finalmask'), isFalse);
    });

    test('the dead udphop claim is gone from the outbound', () {
      final out = buildOutbound(_hy2(upMbps: 100, downMbps: 200), XraySettings())!;
      final raw = jsonEncode(out);
      expect(raw, isNot(contains('udphop')));
    });

    test('codec exports up/down so a shared profile keeps them', () {
      final link = profileToLink(_hy2(upMbps: 100, downMbps: 200));
      expect(link, contains('up=100'));
      expect(link, contains('down=200'));
      final again = parseLink(link)!;
      expect(again.upMbps, 100);
      expect(again.downMbps, 200);
    });
  });

  group('F-H7 SOCKS credentials: builder carries them', () {
    test('a SOCKS profile with credentials emits the users array', () {
      final p = Profile(
        id: 's1',
        protocol: Protocol.socks,
        name: 's',
        address: 'socks.example.com',
        port: 1080,
        uuidOrPassword: 'secret',
        username: 'rayan',
      );
      final out = buildOutbound(p, XraySettings())!;
      final servers =
          (out['settings'] as Map<String, dynamic>)['servers'] as List;
      final server = servers.first as Map<String, dynamic>;
      expect(server['users'], [
        {'user': 'rayan', 'pass': 'secret'},
      ]);
    });

    test('a SOCKS profile without credentials emits no users key', () {
      final p = Profile(
        id: 's2',
        protocol: Protocol.socks,
        name: 's',
        address: 'socks.example.com',
        port: 1080,
      );
      final out = buildOutbound(p, XraySettings())!;
      final servers =
          (out['settings'] as Map<String, dynamic>)['servers'] as List;
      final server = servers.first as Map<String, dynamic>;
      expect(server.containsKey('users'), isFalse);
    });

    test('a SOCKS link round-trips its credentials', () {
      final p = parseLink(
        'socks://cmF5YW46c2VjcmV0@socks.example.com:1080#s',
      )!;
      expect(p.username, 'rayan');
      expect(p.uuidOrPassword, 'secret');
      expect(profileToLink(p), contains('socks://'));
      expect(parseLink(profileToLink(p))!.username, 'rayan');
    });
  });

  group('F-H7 SOCKS credentials: the editor creates them', () {
    testWidgets('username + password typed in the editor reach the profile',
        (tester) async {
      final xray = XrayController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfileEditorPage(xray: xray),
        ),
      );
      await tester.pumpAndSettle();
      // The protocol chips scroll horizontally — SOCKS5 sits
      // off-screen to the right until scrolled into view.
      await tester.ensureVisible(find.text('SOCKS5'));
      await tester.pumpAndSettle();
      // Build 2059: the editor body extends behind the transparent
      // app bar, so ensureVisible can park the chips under it —
      // pull the list down so the chip is tappable, not covered.
      await tester.drag(find.byType(ListView).first, const Offset(0, 120));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SOCKS5'));
      await tester.pumpAndSettle();
      // The credential rows exist now (F-H7: before this build
      // there was no username field anywhere in the editor).
      final userField = _field('Username');
      final passField = _field('Password');
      expect(userField, findsOneWidget);
      expect(passField, findsOneWidget);
      await tester.ensureVisible(_field('Address'));
      await tester.enterText(_field('Address'), 'socks.example.com');
      await tester.enterText(userField, 'rayan');
      await tester.enterText(passField, 'secret');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles, hasLength(1));
      final saved = xray.profiles.single;
      expect(saved.protocol, Protocol.socks);
      expect(saved.address, 'socks.example.com');
      expect(saved.username, 'rayan');
      expect(saved.uuidOrPassword, 'secret');
      final out = buildOutbound(saved, XraySettings())!;
      final servers =
          (out['settings'] as Map<String, dynamic>)['servers'] as List;
      expect(
        (servers.first as Map<String, dynamic>)['users'],
        [
          {'user': 'rayan', 'pass': 'secret'},
        ],
      );
    });

    testWidgets('the Hy2 pin row binds tlsCertPin, not fingerprint',
        (tester) async {
      final xray = XrayController();
      final existing = _hy2(fingerprint: _pin);
      // The editor updates the controller's copy of the profile,
      // so the profile must already live in the controller.
      xray.profiles.add(existing);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfileEditorPage(xray: xray, existing: existing),
        ),
      );
      await tester.pumpAndSettle();
      // The legacy fingerprint pin is migrated on open: the
      // pinSHA256 row shows the pin, and saving keeps it in
      // tlsCertPin instead of the overloaded fingerprint field.
      final pinField = _field('pinSHA256');
      expect(pinField, findsOneWidget);
      expect(
        (pinField.evaluate().single.widget as TextField)
            .controller
            ?.text,
        _pin,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles, hasLength(1));
      final saved = xray.profiles.single;
      expect(saved.tlsCertPin, _pin);
      expect(saved.fingerprint, isEmpty);
    });
  });
}
