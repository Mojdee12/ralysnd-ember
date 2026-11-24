/// Build 2089 gates — AnyTLS run-mode via the sing-box
/// sidecar (pick-order item 3: a parked item become
/// honestly possible). AnyTLS was parsed, stored and
/// shareable since build 2033 but refused to connect: the
/// bundled Xray core has no AnyTLS outbound and no engine
/// served it. The vendored sing-box sidecar is 1.14.4, and
/// sing-box 1.12+ ships an anytls outbound — verified
/// POSITIVELY here, not assumed: the real 1.14.4 binary
/// (`sing-box check`) accepts the minimal outbound, +alpn
/// and +utls fingerprint shapes this build emits, and
/// rejects an unknown fingerprint ("unknown uTLS
/// fingerprint") and an unknown outbound type (the
/// mieru control) — so the check validates.
/// Pinned here:
///   1. AnyTLS is servedBySingBox / servedBySidecar /
///      connectable; the Xray core still has no outbound
///      for it (buildOutbound stays null).
///   2. The emitted sing-box outbound shape — password,
///      server, port, TLS server_name/ALPN, and the uTLS
///      fingerprint allowlist: a stored value sing-box
///      rejects is dropped, never passed through, so a
///      pasted profile can never break the sidecar start.
///   3. The editor no longer tells the user AnyTLS cannot
///      connect — it says it runs on the sing-box engine,
///      like TUIC.
/// What only the owner's phone can prove — a real AnyTLS
/// server answering through the sidecar — is NOT claimed
/// here: the host check validates the config shape only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile _anytls({
  String cred = 'secretpw',
  String address = 'at.example.com',
  int port = 8443,
  String sni = 'at.example.com',
  String alpn = '',
  String fingerprint = '',
}) =>
    Profile(
      id: 'any1',
      protocol: Protocol.anytls,
      address: address,
      port: port,
      uuidOrPassword: cred,
    )
      ..sni = sni
      ..alpn = alpn
      ..fingerprint = fingerprint;

Map<String, dynamic> _outbound(Profile p) =>
    (buildSingBoxConfig(p)['outbounds'] as List).single
        as Map<String, dynamic>;

void main() {
  group('AnyTLS service truth (build 2089)', () {
    test('AnyTLS is served by the sing-box sidecar now', () {
      const p = Protocol.anytls;
      expect(p.servedBySingBox, isTrue);
      expect(p.servedBySidecar, isTrue);
      expect(p.connectable, isTrue);
      // The Xray core itself still has no AnyTLS outbound.
      expect(p.supportedByCore, isFalse);
      expect(
        buildOutbound(_anytls(), XraySettings()),
        isNull,
      );
    });

    test('no parsed protocol is unserved anymore', () {
      for (final p in Protocol.values) {
        expect(p.connectable, isTrue, reason: p.label);
      }
    });

    test('the sidecar refuses a malformed AnyTLS profile in plain language',
        () {
      expect(
        singBoxConfigError(_anytls(cred: '')),
        contains('no password'),
      );
      expect(
        singBoxConfigError(_anytls(address: '')),
        contains('no server'),
      );
      expect(singBoxConfigError(_anytls()), isNull);
    });
  });

  group('AnyTLS sing-box outbound shape (build 2089)', () {
    test('minimal outbound carries password, server, TLS server_name', () {
      final out = _outbound(_anytls());
      expect(
        out,
        {
          'type': 'anytls',
          'tag': 'proxy',
          'server': 'at.example.com',
          'server_port': 8443,
          'password': 'secretpw',
          'tls': {'enabled': true, 'server_name': 'at.example.com'},
        },
      );
    });

    test('SNI falls back to the address; ALPN is split and trimmed', () {
      final p = _anytls(sni: '', alpn: ' h2 , http/1.1 ');
      final tls = _outbound(p)['tls'] as Map<String, dynamic>;
      expect(tls['server_name'], 'at.example.com');
      expect(tls['alpn'], ['h2', 'http/1.1']);
      expect(tls.containsKey('utls'), isFalse);
    });

    test('a known fingerprint becomes a uTLS fingerprint', () {
      final p = _anytls(fingerprint: 'chrome');
      final tls = _outbound(p)['tls'] as Map<String, dynamic>;
      expect(tls['utls'], {
        'enabled': true,
        'fingerprint': 'chrome',
      });
    });

    test('the fingerprint match is case-insensitive and trimmed', () {
      final p = _anytls(fingerprint: '  Chrome ');
      final tls = _outbound(p)['tls'] as Map<String, dynamic>;
      expect(
        (tls['utls'] as Map)['fingerprint'],
        'chrome',
      );
    });

    test('an unknown stored fingerprint is dropped, never passed through',
        () {
      // sing-box check rejects an unknown fingerprint at
      // load ("unknown uTLS fingerprint: bogusfp"), which
      // would break the sidecar start for a pasted profile
      // — so the emitter drops it and keeps the session.
      for (final fp in ['bogusfp', 'tls13', 'firefox-esr']) {
        final p = _anytls(fingerprint: fp);
        final tls = _outbound(p)['tls'] as Map<String, dynamic>;
        expect(tls.containsKey('utls'), isFalse, reason: fp);
      }
    });

    test('every allowlisted fingerprint is emitted', () {
      for (final fp in singBoxUtlsFingerprints) {
        final p = _anytls(fingerprint: fp);
        final tls = _outbound(p)['tls'] as Map<String, dynamic>;
        expect(
          (tls['utls'] as Map)['fingerprint'],
          fp,
          reason: fp,
        );
      }
    });

    test('the full sidecar config matches the checked shape', () {
      final cfg = buildSingBoxConfig(_anytls());
      final inbound = (cfg['inbounds'] as List).single
          as Map<String, dynamic>;
      expect(inbound['type'], 'mixed');
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['listen_port'], singBoxListenPort);
      expect((cfg['route'] as Map)['final'], 'proxy');
      // This exact JSON is what `sing-box check` accepted
      // against the vendored 1.14.4 binary (c1/c2 in the
      // build log): one mixed inbound, one anytls outbound.
      expect(jsonEncode(cfg), contains('"type":"anytls"'));
    });

    test('a parsed anytls:// link feeds the sidecar config', () {
      final p = parseLink(
        'anytls://secretpw@at.example.com:8443/'
        '?security=tls&sni=at.example.com&fp=chrome#AT%20one',
      );
      expect(p, isNotNull);
      final out = _outbound(p!);
      expect(out['password'], 'secretpw');
      expect(out['server'], 'at.example.com');
      expect(
        (out['tls'] as Map)['server_name'],
        'at.example.com',
      );
      expect(
        ((out['tls'] as Map)['utls'] as Map)['fingerprint'],
        'chrome',
      );
    });
  });

  group('AnyTLS editor notice (build 2089)', () {
    test('the editor says AnyTLS runs on sing-box, not that it cannot connect',
        () {
      final src = File(
        'lib/ui/ember/profile_editor.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('AnyTLS connects through the sing-box engine'),
      );
      expect(src, isNot(contains('cannot connect yet')));
    });
  });
}
