/// Build 2043 gates, host side: Config Mixins — the user's own
/// JSON object, merged into the tunnel config at the end of every
/// build (LxBox v2.25.19-rc.2 suggestion, 2026-11-13). Verified
/// honest before building: the app builds the tunnel config JSON
/// in Dart (config_builder.buildTunnelConfig) and hands the string
/// to the core, so a user object merged at the end of that build
/// is the same mechanism, not a new engine — no core change.
/// These tests pin the Dart side of that contract: parsing
/// (invalid JSON is refused, never half-applied), the merge rules
/// (maps recurse, lists append so the api-first routing rule stays
/// first, scalars replace), storage, and the emitted config —
/// including the no-regression cases that an empty mixin emits
/// exactly the old config, an invalid stored mixin is skipped
/// rather than breaking a connect, and the delay-test config is
/// never mixed in.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/config_mixins.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

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

Map<String, dynamic> tunnelCfg(XraySettings s) =>
    decode(buildTunnelConfig(_vless(), s));

void main() {
  group('Config mixins parsing (build 2043)', () {
    test('empty or blank text means no mixins, not an error', () {
      for (final raw in ['', '   ', '\n\t ']) {
        final parsed = parseConfigMixins(raw);
        expect(parsed.mixins, isNull);
        expect(parsed.error, isNull);
      }
    });

    test('a JSON object parses to its map', () {
      final parsed = parseConfigMixins('{"log": {"loglevel": "info"}}');
      expect(parsed.error, isNull);
      expect(parsed.mixins, {
        'log': {'loglevel': 'info'},
      });
    });

    test('a non-object top level is an error', () {
      for (final raw in ['[]', '"just a string"', '42', 'true', 'null']) {
        final parsed = parseConfigMixins(raw);
        expect(parsed.mixins, isNull);
        expect(parsed.error, isNotNull);
      }
    });

    test('malformed JSON is an error naming the problem', () {
      final parsed = parseConfigMixins('{"log": ');
      expect(parsed.mixins, isNull);
      expect(parsed.error, contains('Invalid JSON'));
      final trailing = parseConfigMixins('{"a": 1} trailing');
      expect(trailing.error, contains('Invalid JSON'));
    });

    test('mixinsFromStoredText is null for empty or invalid text', () {
      expect(mixinsFromStoredText(''), isNull);
      expect(mixinsFromStoredText('not json'), isNull);
      expect(
        mixinsFromStoredText('{"log": {"loglevel": "info"}}'),
        isNotNull,
      );
    });
  });

  group('Config mixins merge rules (build 2043)', () {
    test('scalars replace, maps recurse, siblings survive', () {
      final base = decode(
        '{"log": {"loglevel": "warning"}, "dns": {"servers": ["a"], "queryStrategy": "UseIP"}}',
      );
      final merged = applyConfigMixins(base, decode(
        '{"log": {"loglevel": "info"}, "dns": {"queryStrategy": "UseIPv4"}}',
      ));
      expect((merged['log'] as Map)['loglevel'], 'info');
      expect((merged['dns'] as Map)['servers'], ['a']);
      expect((merged['dns'] as Map)['queryStrategy'], 'UseIPv4');
    });

    test('lists append — the api routing rule stays first', () {
      final base = decode(
        '{"routing": {"rules": [{"outboundTag": "api"}, {"outboundTag": "proxy"}]}}',
      );
      final merged = applyConfigMixins(base, decode(
        '{"routing": {"rules": [{"outboundTag": "block", "domain": ["ads.example"]}]}}',
      ));
      final rules = (merged['routing'] as Map)['rules'] as List;
      expect(rules.length, 3);
      expect((rules[0] as Map)['outboundTag'], 'api');
      expect((rules[2] as Map)['outboundTag'], 'block');
    });

    test('new top-level keys are added', () {
      final base = decode('{"log": {"loglevel": "warning"}}');
      final merged = applyConfigMixins(base, decode(
        '{"observatory": {"subjectSelector": ["proxy"]}}',
      ));
      expect(merged['observatory'], {
        'subjectSelector': ['proxy'],
      });
      expect((merged['log'] as Map)['loglevel'], 'warning');
    });

    test('the mixin map itself is not mutated', () {
      final base = decode('{"routing": {"rules": [{"a": 1}]}}');
      final mixins = decode(
        '{"routing": {"rules": [{"b": 2}]}, "log": {"loglevel": "info"}}',
      );
      applyConfigMixins(base, mixins);
      expect((mixins['routing'] as Map)['rules'], [
        {'b': 2},
      ]);
      expect((mixins['log'] as Map)['loglevel'], 'info');
    });
  });

  group('Config mixins storage (build 2043)', () {
    test('default is no mixins', () {
      expect(XraySettings().configMixins, '');
    });

    test('an old store without the key reads the default', () {
      expect(XraySettings.fromJson({}).configMixins, '');
    });

    test('round-trip keeps the text as written', () {
      const text = '{\n  "log": {"loglevel": "info"}\n}';
      final s = XraySettings()..configMixins = text;
      expect(XraySettings.fromJson(s.toJson()).configMixins, text);
    });

    test('a non-string stored value reads as no mixins', () {
      expect(
        XraySettings.fromJson({'configMixins': 42}).configMixins,
        '',
      );
      expect(
        XraySettings.fromJson({
          'configMixins': {'log': 'x'},
        }).configMixins,
        '',
      );
    });
  });

  group('Config mixins in the built config (build 2043)', () {
    test('a mixin reaches the tunnel config', () {
      final s = XraySettings()
        ..configMixins =
            '{"log": {"loglevel": "info"}, "routing": {"rules": [{"type": "field", "domain": ["ads.example"], "outboundTag": "block"}]}}';
      final cfg = tunnelCfg(s);
      expect((cfg['log'] as Map)['loglevel'], 'info');
      final rules = (cfg['routing'] as Map)['rules'] as List;
      expect((rules.first as Map)['outboundTag'], 'api');
      expect(
        (rules.last as Map)['outboundTag'],
        'block',
      );
      // Everything else is untouched: the proxy outbound, the
      // stats API and the DNS section are exactly as generated.
      expect((cfg['outbounds'] as List).first['protocol'], 'vless');
      expect(cfg['api'], isNotNull);
      expect(cfg['dns'], isNotNull);
    });

    test('no mixins emits exactly the old config', () {
      final plain = buildTunnelConfig(_vless(), XraySettings());
      final empty = buildTunnelConfig(
        _vless(),
        XraySettings()..configMixins = '  ',
      );
      expect(empty, plain);
    });

    test('invalid stored mixins are skipped, never break a connect', () {
      final s = XraySettings()..configMixins = '{"log": ';
      final cfg = tunnelCfg(s);
      expect((cfg['log'] as Map)['loglevel'], 'warning');
      expect((cfg['outbounds'] as List).first['protocol'], 'vless');
    });

    test('the delay-test config is never mixed in', () {
      final s = XraySettings()
        ..configMixins = '{"log": {"loglevel": "info"}}';
      final cfg = decode(buildTestConfig(_vless(), s));
      expect((cfg['log'] as Map)['loglevel'], 'none');
      expect(cfg.containsKey('routing'), isFalse);
    });
  });
}
