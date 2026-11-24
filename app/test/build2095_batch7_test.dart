/// Build 2095, batch 7 gates — the BURIED/MISSING basics:
/// - #27 per-profile mux override (model + builder),
/// - #22 per-protocol sniffing toggles (model + builder),
/// - #28 core log level (model + builder),
/// - #23 bypass-China routing preset (builder),
/// - #15 app settings ride the backup, secrets stripped,
/// - #33 .conf serializer round-trips through the parser,
/// - #38 deep-link argument parsing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/net/network_info.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/wg_conf.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

Map<String, dynamic> decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile vless({String muxOverride = ''}) => Profile(
  id: 'v1',
  protocol: Protocol.vless,
  name: 'v',
  address: 'v.example.com',
  port: 443,
  uuidOrPassword: '11111111-2222-3333-4444-555555555555',
  security: 'tls',
  muxOverride: muxOverride,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#27 mux override', () {
    test('model round-trips; old JSON defaults to inherit', () {
      expect(vless(muxOverride: 'on').toJson()['muxOverride'], 'on');
      expect(
        Profile.fromJson(vless(muxOverride: 'off').toJson()).muxOverride,
        'off',
      );
      expect(
        Profile.fromJson({'id': 'x', 'protocol': 'vless'}).muxOverride,
        '',
      );
    });

    test('builder: override on forces mux with global off', () {
      final out = buildOutbound(
        vless(muxOverride: 'on'),
        XraySettings()..muxEnabled = false,
      )!;
      expect((out['mux'] as Map)['enabled'], isTrue);
    });

    test('builder: override off suppresses a global on', () {
      final out = buildOutbound(
        vless(muxOverride: 'off'),
        XraySettings()..muxEnabled = true,
      )!;
      expect(out.containsKey('mux'), isFalse);
    });

    test('builder: inherit follows the global switch', () {
      final on = buildOutbound(
        vless(),
        XraySettings()..muxEnabled = true,
      )!;
      expect((on['mux'] as Map)['enabled'], isTrue);
      final off = buildOutbound(
        vless(),
        XraySettings()..muxEnabled = false,
      )!;
      expect(off.containsKey('mux'), isFalse);
    });
  });

  group('#22 sniffing toggles + #28 log level', () {
    test('settings round-trip; defaults keep the old shape', () {
      final s = XraySettings();
      // Build 2103 (diagnosis D3/E3): sniffQuic's default
      // is OFF now — v2rayNG sniffs http+tls only; the
      // other two still default ON.
      expect(s.sniffHttp && s.sniffTls, isTrue);
      expect(s.sniffQuic, isFalse);
      expect(s.logLevel, 'warning');
      final s2 = XraySettings.fromJson(
        (s..sniffTls = false).toJson(),
      );
      expect(s2.sniffTls, isFalse);
      expect(s2.sniffHttp, isTrue);
    });

    test('builder: destOverride follows the toggles', () {
      final cfg = decode(
        buildTunnelConfig(
          vless(),
          XraySettings()
            ..sniffHttp = false
            ..sniffQuic = false,
        ),
      );
      final inbounds = cfg['inbounds'] as List;
      final sniffing =
          (inbounds.first as Map)['sniffing'] as Map<String, dynamic>;
      expect(sniffing['destOverride'], ['tls']);
    });

    test('builder: the log level lands in the main config', () {
      final cfg = decode(
        buildTunnelConfig(vless(), XraySettings()..logLevel = 'debug'),
      );
      expect((cfg['log'] as Map)['loglevel'], 'debug');
    });
  });

  group('#23 bypass-China preset', () {
    test('builder emits the CN direct rules', () {
      final cfg = decode(
        buildTunnelConfig(
          vless(),
          XraySettings()..routingPreset = RoutingPreset.bypassChina,
        ),
      );
      final rules = (cfg['routing'] as Map)['rules'] as List;
      final flat = rules.map((r) => jsonEncode(r)).join(' ');
      expect(flat, contains('geoip:cn'));
      expect(flat, contains('geosite:cn'));
      expect(RoutingPreset.bypassChina.name, 'bypass-china');
      expect(
        XraySettings.fromJson(
          (XraySettings()..routingPreset = RoutingPreset.bypassChina)
              .toJson(),
        ).routingPreset,
        RoutingPreset.bypassChina,
      );
    });
  });

  group('#15 backup carries app settings, secrets stripped', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2095-b7-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), (
            call,
          ) async {
            if (call.method == 'dataDir') return '${tempDir.path}/core';
            return null;
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
      await tempDir.delete(recursive: true);
    });

    test('export embeds the settings minus token + PIN hash', () async {
      final c = XrayController();
      final json = await c.exportBackup(
        appSettingsJson: {
          'language': 'en',
          'sync_github_token': 'ghp_secret',
          'app_lock_pin_hash': 'hash',
        },
      );
      final doc = decode(json!);
      final carried = doc['appSettings'] as Map<String, dynamic>;
      expect(carried['language'], 'en');
      expect(carried.containsKey('sync_github_token'), isFalse);
      expect(carried.containsKey('app_lock_pin_hash'), isFalse);
    });

    test('import returns the settings, stripped again', () async {
      final c = XrayController();
      final backup = jsonEncode({
        'profiles': <Object?>[],
        'subscriptions': <Object?>[],
        'appSettings': {
          'theme': 'dark',
          'sync_github_token': 'ghp_secret',
          'app_lock_pin_hash': 'hash',
        },
      });
      final result = await c.importBackup(backup);
      expect(result, isNotNull);
      expect(result!.appSettingsJson?['theme'], 'dark');
      expect(
        result.appSettingsJson!.containsKey('sync_github_token'),
        isFalse,
      );
      expect(
        result.appSettingsJson!.containsKey('app_lock_pin_hash'),
        isFalse,
      );
    });

    test('applyRestoredSettings lands values, keeps live secrets', () async {
      final s = AppSettings();
      s.syncGithubToken = 'live-token';
      await s.applyRestoredSettings({'language': 'fa', 'theme': 'light'});
      expect(s.language, 'fa');
      expect(s.syncGithubToken, 'live-token');
    });
  });

  group('#33 .conf serializer round-trip', () {
    test('serialize → parse preserves the config', () {
      final p = Profile(
        id: 'w1',
        protocol: Protocol.wireguard,
        name: 'wg',
        address: 'wg.example.com',
        port: 51820,
        secretKey: 'PRIVKEY=',
        peerPublicKey: 'PUBKEY=',
        preSharedKey: 'PSK=',
        localAddress: '10.0.0.2/32',
        wgAllowedIPs: '0.0.0.0/0, ::/0',
        wgDns: '1.1.1.1',
        mtu: 1420,
        keepAlive: 25,
      );
      final text = wgConfFromProfile(p);
      expect(text, contains('[Interface]'));
      expect(text, contains('[Peer]'));
      var n = 0;
      final parsed = parseWgConf(text, baseName: 'wg', idFor: () => 'id${n++}');
      expect(parsed.ok, isTrue, reason: parsed.error);
      final q = parsed.profiles.single;
      expect(q.secretKey, p.secretKey);
      expect(q.peerPublicKey, p.peerPublicKey);
      expect(q.preSharedKey, p.preSharedKey);
      expect(q.address, p.address);
      expect(q.port, p.port);
      expect(q.wgAllowedIPs, '0.0.0.0/0,::/0');
      expect(q.wgDns, '1.1.1.1');
      expect(q.keepAlive, 25);
    });
  });

  group('#38 deep-link arguments', () {
    test('the link shape parses; everything else is null', () {
      expect(
        parseDeepLinkArgs({'link': 'vless://x@y:443#n'}),
        'vless://x@y:443#n',
      );
      expect(parseDeepLinkArgs({'link': ''}), isNull);
      expect(parseDeepLinkArgs({'profileId': 'x'}), isNull);
      expect(parseDeepLinkArgs(null), isNull);
      expect(parseDeepLinkArgs('vless://x'), isNull);
    });
  });
}
