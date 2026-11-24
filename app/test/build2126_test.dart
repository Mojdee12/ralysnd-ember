// Build 2126 gates — feature picks 3–6 from the
// 2026-11-21 feature-watch digest (owner order
// 2026-11-21 04:14: items 1 ShadowQUIC and 2 Juicity are
// EXCLUDED and untouched by this build).
//
// Dispositions proven in analysis (build2126-progress.md):
//   3. ShadowTLS v3 — LANDED here. The vendored sing-box
//      1.14.4 binary contains sing-shadowtls; the outbound
//      grammar is proven from the v1.14.4 source
//      (option/shadowtls.go + protocol/shadowtls/outbound.go:
//      TLS required, version 0 defaults to 1, the SS
//      outbound detours through the front) and the emitted
//      shape passed `sing-box check` against the real
//      1.14.4 binary (classic + 2022 ciphers; the no-TLS
//      negative control fails with "TLS required").
//      Pinned below: the plugin parse, the emitted pair,
//      the plain-language errors, the settings gate
//      (default OFF, persisted), the chain refusal, and
//      OFF byte-identity of the Xray path.
//   4. OLCRTC — PARKED (no vendored core carries it; a new
//      native engine + third-party meet-room transport +
//      a breaking upstream protocol revision make it
//      unprovable end-to-end here). Nothing to pin.
//   5. VLESS/Trojan ECH — ALREADY PRESENT since builds
//      2029A/2033/2116 (pinned by build2033/build2116
//      suites). Nothing to land, nothing pinned here.
//   6. WireGuard over TCP — ALREADY PRESENT since build
//      2072 (wgWstunnel; pinned by build2072_test.dart).
//      Nothing to land, nothing pinned here.
//
// What only the owner's phone can prove — a real
// ShadowTLS server answering through the sidecar — is NOT
// claimed here: the host check validates the config shape
// only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/chain_builder_page.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/dpi_remote.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _dart(String rel) => File('lib/$rel').readAsStringSync();

Profile _ss({
  String plugin = '',
  String method = 'aes-128-gcm',
  String address = '203.0.113.7',
  int port = 8388,
}) => Profile(
  id: 'ss1',
  protocol: Protocol.shadowsocks,
  name: 'ss',
  address: address,
  port: port,
  uuidOrPassword: 'ss-password',
  method: method,
  plugin: plugin,
);

const _pluginV3 =
    'shadow-tls;host=gateway.icloud.com;password=tls-password;version=3';

void main() {
  group('build 2126 — ShadowTLS plugin parse', () {
    test('full v3 plugin parses host/password/version', () {
      final st = _ss(plugin: _pluginV3).shadowTlsPlugin;
      expect(st, isNotNull);
      expect(st!.host, 'gateway.icloud.com');
      expect(st.password, 'tls-password');
      expect(st.version, 3);
    });

    test('absent version defaults to 3; v1/v2 honoured', () {
      expect(
        _ss(plugin: 'shadow-tls;host=h.example;password=p').shadowTlsPlugin
            ?.version,
        3,
      );
      expect(
        _ss(plugin: 'shadow-tls;host=h.example;version=2').shadowTlsPlugin
            ?.version,
        2,
      );
      expect(
        _ss(plugin: 'shadow-tls;host=h.example;version=1').shadowTlsPlugin
            ?.version,
        1,
      );
    });

    test('a future or malformed version is NOT frontable', () {
      expect(_ss(plugin: 'shadow-tls;host=h;version=4').shadowTlsPlugin, isNull);
      expect(
        _ss(plugin: 'shadow-tls;host=h;version=x').shadowTlsPlugin,
        isNull,
      );
    });

    test('other plugins and empty plugin parse to null', () {
      expect(_ss(plugin: 'obfs-local;obfs=http').shadowTlsPlugin, isNull);
      expect(_ss(plugin: 'v2ray-plugin;mode=websocket').shadowTlsPlugin, isNull);
      expect(_ss().shadowTlsPlugin, isNull);
    });

    test('percent-encoded option values are decoded once', () {
      final st = _ss(
        plugin: 'shadow-tls;host=h.example;password=p%40ss%3Bword;version=3',
      ).shadowTlsPlugin;
      expect(st!.password, 'p@ss;word');
    });

    test('the getter is Shadowsocks-only', () {
      final vless = Profile(
        id: 'v1',
        protocol: Protocol.vless,
        address: 'a.example',
        port: 443,
        uuidOrPassword: 'u',
        plugin: _pluginV3,
      );
      expect(vless.shadowTlsPlugin, isNull);
    });

    test('a shadow-tls profile is NOT intrinsically sidecar-served', () {
      // The diversion is the controller's settings decision;
      // the profile's own truth (2125) is unchanged, so with
      // the setting off nothing anywhere re-routes it.
      final p = _ss(plugin: _pluginV3);
      expect(p.servedBySidecar, isFalse);
      expect(p.hasUnsupportedPlugin, isTrue);
    });

    test('an ss:// link carries the plugin into the parse', () {
      final userInfo = base64Url.encode(
        utf8.encode('aes-128-gcm:ss-password'),
      );
      final plugin = Uri.encodeComponent(_pluginV3);
      final p = parseLink(
        'ss://$userInfo@203.0.113.7:8388?plugin=$plugin#fronted',
      );
      expect(p, isNotNull);
      expect(p!.protocol, Protocol.shadowsocks);
      expect(p.shadowTlsPlugin, isNotNull);
      expect(p.shadowTlsPlugin!.host, 'gateway.icloud.com');
    });
  });

  group('build 2126 — ShadowTLS sing-box emission', () {
    test('the fronted pair: SS detours through the front', () {
      final cfg = buildSingBoxConfig(_ss(plugin: _pluginV3));
      final outbounds = cfg['outbounds'] as List;
      expect(outbounds, hasLength(2));
      final ss = outbounds[0] as Map<String, dynamic>;
      expect(ss, {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': '203.0.113.7',
        'server_port': 8388,
        'method': 'aes-128-gcm',
        'password': 'ss-password',
        'detour': shadowTlsOutboundTag,
      });
      final front = outbounds[1] as Map<String, dynamic>;
      expect(front, {
        'type': 'shadowtls',
        'tag': shadowTlsOutboundTag,
        'server': '203.0.113.7',
        'server_port': 8388,
        'version': 3,
        'password': 'tls-password',
        'tls': {'enabled': true, 'server_name': 'gateway.icloud.com'},
      });
      expect((cfg['route'] as Map)['final'], 'proxy');
      final inbound = (cfg['inbounds'] as List).single as Map<String, dynamic>;
      expect(inbound['listen_port'], singBoxListenPort);
    });

    test('a 2022 cipher profile emits the same pair', () {
      final cfg = buildSingBoxConfig(
        _ss(plugin: _pluginV3, method: '2022-blake3-aes-128-gcm'),
      );
      final ss = (cfg['outbounds'] as List)[0] as Map<String, dynamic>;
      expect(ss['method'], '2022-blake3-aes-128-gcm');
      expect(ss['detour'], shadowTlsOutboundTag);
    });

    test('v1 without a password emits no password key', () {
      final cfg = buildSingBoxConfig(
        _ss(plugin: 'shadow-tls;host=h.example;version=1'),
      );
      final front = (cfg['outbounds'] as List)[1] as Map<String, dynamic>;
      expect(front['version'], 1);
      expect(front.containsKey('password'), isFalse);
    });

    test('a plain SS profile emits one outbound, no detour', () {
      final cfg = buildSingBoxConfig(_ss());
      final outbounds = cfg['outbounds'] as List;
      expect(outbounds, hasLength(1));
      final ss = outbounds.single as Map<String, dynamic>;
      expect(ss['type'], 'shadowsocks');
      expect(ss.containsKey('detour'), isFalse);
    });

    test('plain-language errors before any process starts', () {
      expect(singBoxConfigError(_ss(plugin: _pluginV3)), isNull);
      expect(
        singBoxConfigError(_ss(plugin: 'shadow-tls;password=p;version=3')),
        contains('handshake host'),
      );
      expect(
        singBoxConfigError(_ss(plugin: 'shadow-tls;host=h.example;version=3')),
        contains('password'),
      );
      // v1 needs no password.
      expect(
        singBoxConfigError(_ss(plugin: 'shadow-tls;host=h.example;version=1')),
        isNull,
      );
      expect(singBoxConfigError(_ss()), contains('no ShadowTLS plugin'));
      expect(
        singBoxConfigError(_ss(plugin: _pluginV3, address: '')),
        contains('no server'),
      );
    });
  });

  group('build 2126 — the settings gate', () {
    test('shadowTlsFronting defaults OFF and persists', () {
      expect(XraySettings().shadowTlsFronting, isFalse);
      expect(
        XraySettings().toJson(),
        containsPair('shadowTlsFronting', false),
      );
      final on = XraySettings()..shadowTlsFronting = true;
      expect(XraySettings.fromJson(on.toJson()).shadowTlsFronting, isTrue);
      // A pre-2126 store (no key) keeps it off.
      final legacy = XraySettings().toJson()..remove('shadowTlsFronting');
      expect(XraySettings.fromJson(legacy).shadowTlsFronting, isFalse);
    });

    test('OFF: the Xray tunnel config is byte-identical with/without '
        'the plugin on the profile', () {
      // The Xray builder never emitted the plugin (build
      // 2057) and build 2126 does not change that: the whole
      // tunnel config for a shadow-tls profile equals the
      // config for the same profile with no plugin at all.
      final withPlugin = buildTunnelConfig(
        _ss(plugin: _pluginV3),
        XraySettings(),
      );
      final without = buildTunnelConfig(_ss(), XraySettings());
      expect(withPlugin, without);
      expect(withPlugin.contains('shadowtls'), isFalse);
      expect(withPlugin.contains('shadowTls'), isFalse);
    });

    test('the controller gate is the setting AND the parse', () {
      final controller = _dart('xray/xray_controller.dart');
      expect(
        controller,
        contains(
          'settings.shadowTlsFronting && p.shadowTlsPlugin != null',
        ),
      );
      // Every controller sidecar decision reads the
      // effective predicate, not the profile getter alone.
      expect(controller, contains('bool servedViaSidecar(Profile p)'));
      expect(
        'servedViaSidecar('.allMatches(controller).length,
        greaterThanOrEqualTo(6),
      );
      // The not-applied journal is suppressed for a
      // diverted profile (its plugin IS applied).
      expect(
        controller,
        contains('p.hasUnsupportedPlugin && !shadowTlsServed(p)'),
      );
    });

    test('the settings row exists and writes the setting', () {
      final settings = _dart('ui/ember/ember_settings.dart');
      expect(settings, contains('ShadowTLS fronting (Shadowsocks)'));
      expect(settings, contains('s.shadowTlsFronting = v;'));
    });
  });

  group('build 2126 — chain gate', () {
    Profile exit() => _ss(plugin: _pluginV3);

    test('fronting ON refuses a ShadowTLS exit', () {
      final refusal = validateChainEntry(
        name: 'c',
        underlay: 'warp',
        profileId: 'ss1',
        profiles: [exit()],
        shadowTlsFronting: true,
      );
      expect(refusal, contains('served by the sidecar core'));
    });

    test('fronting OFF keeps the 2125 answer (no refusal)', () {
      final refusal = validateChainEntry(
        name: 'c',
        underlay: 'warp',
        profileId: 'ss1',
        profiles: [exit()],
      );
      expect(refusal, isNull);
    });
  });

  // ---- Scope expansion 1: the A26 audit fixes ----

  group('build 2126 — A26-01 + A26-07 re-proof', () {
    final controller = _dart('xray/xray_controller.dart');

    test('the re-proof path demands a FRESH proof', () {
      expect(controller, contains('bool freshProof = false'));
      expect(controller, contains('freshProof: true'));
      // The fresh branch decides on a live tunnel check;
      // the cached exit verdict plays no part in it.
      final start = controller.indexOf('if (freshProof) {');
      expect(start, greaterThan(0));
      final slice = controller.substring(start, start + 420);
      expect(slice, contains('XrayPlatform.tunnelCheck'));
      expect(slice, isNot(contains('exitInfo')));
      // A passed fresh proof refreshes the displayed exit.
      expect(controller, contains('_fetchExitInfo();'));
    });

    test('a failed adoption proof arms the re-proof cadence', () {
      expect(controller, contains('A26-07'));
      final at = controller.indexOf('A26-07');
      final slice = controller.substring(at, at + 900);
      expect(slice, contains('_reproofNextAtMs'));
      expect(slice, contains('_reproofCadenceMs'));
    });
  });

  group('build 2126 — A26-26 defaults law', () {
    test('subUpdateOnLaunch defaults OFF on a fresh store', () {
      expect(XraySettings().subUpdateOnLaunch, isFalse);
      expect(XraySettings().defaultsReset2126, isFalse);
    });

    test('a pre-2126 store with it ON is migrated OFF once', () {
      final legacy = XraySettings().toJson()
        ..['subUpdateOnLaunch'] = true
        ..remove('defaultsReset2126');
      final s = XraySettings.fromJson(legacy);
      expect(s.subUpdateOnLaunch, isFalse);
      expect(s.defaultsReset2126, isTrue);
    });

    test('a post-migration ON choice is kept', () {
      final stored = XraySettings().toJson()
        ..['subUpdateOnLaunch'] = true
        ..['defaultsReset2126'] = true;
      expect(XraySettings.fromJson(stored).subUpdateOnLaunch, isTrue);
    });

    test('the four D toggles default OFF and persist', () {
      final fresh = XraySettings();
      expect(fresh.geckoPacketSizes, isFalse);
      expect(fresh.hy2NoiseDecoy, isFalse);
      expect(fresh.fragmentViaFinalmask, isFalse);
      expect(fresh.sidecarTlsFragment, isFalse);
      final on = XraySettings.fromJson(
        XraySettings().toJson()
          ..['geckoPacketSizes'] = true
          ..['hy2NoiseDecoy'] = true
          ..['fragmentViaFinalmask'] = true
          ..['sidecarTlsFragment'] = true,
      );
      expect(on.geckoPacketSizes, isTrue);
      expect(on.hy2NoiseDecoy, isTrue);
      expect(on.fragmentViaFinalmask, isTrue);
      expect(on.sidecarTlsFragment, isTrue);
    });
  });

  group('build 2126 — A26-19/24/27 updater hardening', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ember2126up');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    Future<EmberUpdater> updaterIn(
      Future<String> Function(Uri) fetcher,
    ) async {
      final settings = await AppSettings.load(dir.path);
      return EmberUpdater(
        settings: settings,
        dataDir: dir.path,
        fetcher: fetcher,
      )..packageBuild = 2071;
    }

    Map<String, dynamic> feedFor(String url, int size) => {
      'tag_name': 'v2099',
      'name': 'Build 2099',
      'body': '',
      'assets': [
        {
          'name': 'RalysndEmber2.apk',
          'browser_download_url': url,
          'size': size,
        },
      ],
    };

    test('a 200 answer to a Range request restarts, never appends', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final half = bytes.length ~/ 2;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var served = 0;
      server.listen((req) async {
        served++;
        if (served == 1) {
          req.response.headers.contentLength = half;
          req.response.add(bytes.sublist(0, half));
        } else {
          // Ignores Range entirely: a full 200 body.
          req.response.headers.contentLength = bytes.length;
          req.response.add(bytes);
        }
        await req.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/RalysndEmber2.apk';
      final u = await updaterIn(
        (_) async => jsonEncode(feedFor(url, bytes.length)),
      );
      u.urlPolicyOverride = (_) => true;
      // Build 2129 (leg 6): the signing-cert check runs through its seam here, like the URL policy above.
      u.certCheckOverride = (_) async => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      await u.download();
      expect(u.state, EmberUpdateState.downloaded);
      expect(File(u.downloadedPath!).readAsBytesSync(), bytes);
    });

    test('a 206 from the wrong offset restarts the whole file', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final half = bytes.length ~/ 2;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var served = 0;
      server.listen((req) async {
        served++;
        if (served == 1) {
          req.response.headers.contentLength = half;
          req.response.add(bytes.sublist(0, half));
        } else if (served == 2) {
          // Claims a resume, but from offset 0 — the part
          // on disk starts at `half`, so this body cannot
          // be appended to it.
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${half - 1}/${bytes.length}',
          );
          req.response.headers.contentLength = half;
          req.response.add(bytes.sublist(0, half));
        } else {
          req.response.headers.contentLength = bytes.length;
          req.response.add(bytes);
        }
        await req.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/RalysndEmber2.apk';
      final u = await updaterIn(
        (_) async => jsonEncode(feedFor(url, bytes.length)),
      );
      u.urlPolicyOverride = (_) => true;
      // Build 2129 (leg 6): the signing-cert check runs through its seam here, like the URL policy above.
      u.certCheckOverride = (_) async => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      await u.download();
      expect(u.state, EmberUpdateState.downloaded);
      expect(served, 3);
      expect(File(u.downloadedPath!).readAsBytesSync(), bytes);
    });

    test('a redirect to a policy-refused address is refused', () async {
      final bytes = List<int>.generate(2048, (i) => i % 251);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        if (req.uri.path == '/start') {
          req.response.statusCode = HttpStatus.found;
          req.response.headers.set(HttpHeaders.locationHeader, '/evil');
        } else {
          req.response.headers.contentLength = bytes.length;
          req.response.add(bytes);
        }
        await req.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/start';
      final u = await updaterIn(
        (_) async => jsonEncode(feedFor(url, bytes.length)),
      );
      u.urlPolicyOverride = (u) => !u.contains('evil');
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      expect(u.downloadedPath, isNull);
    });

    test('check() reports a kept part as resumable bytes', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final half = bytes.length ~/ 2;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.headers.contentLength = half;
        req.response.add(bytes.sublist(0, half));
        await req.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/RalysndEmber2.apk';
      final feed = jsonEncode(feedFor(url, bytes.length));
      final u = await updaterIn((_) async => feed);
      u.urlPolicyOverride = (_) => true;
      await u.check(manual: true);
      await u.download();
      expect(u.state, EmberUpdateState.error);
      final u2 = await updaterIn((_) async => feed);
      u2.urlPolicyOverride = (_) => true;
      await u2.check(manual: true);
      expect(u2.resumableBytes, half);
    });
  });

  group('build 2126 — A26 native pins (Kotlin)', () {
    String kt(String rel) => File(
      'android/app/src/main/kotlin/com/ralysnd/ember/$rel',
    ).readAsStringSync();

    test('A26-04: the OpenVPN hold reads a latch, not the live phase', () {
      final src = kt('OpenVpnService.kt');
      expect(src, contains('wasConnected'));
      // Latched at the verify sites, consumed by the gate.
      expect('wasConnected = true'.allMatches(src).length, greaterThan(1));
      expect(src, contains('wasConnected = false'));
    });

    test('A26-10: XrayVpnService onRevoke marks the stop as the user\'s', () {
      final src = kt('XrayVpnService.kt');
      final at = src.indexOf('override fun onRevoke');
      expect(at, greaterThan(0));
      expect(
        src.substring(at, at + 400),
        contains('userStopped = true'),
      );
    });

    test('A26-09 + A26-29: claim failure journals; tmp orphans sweep', () {
      final claim = kt('EngineClaim.kt');
      expect(claim, contains('engine_claim_lock_failed_fail_open'));
      expect(claim, contains('sweepOrphans'));
    });

    test('A26-18: the WG engine releases its claim on failure exits', () {
      final wg = kt('WgTunnelEngine.kt');
      expect(
        'EngineClaim.release'.allMatches(wg).length,
        greaterThanOrEqualTo(5),
      );
    });
  });

  // ---- Scope expansions 2 + 3: the D items ----

  Profile vlessTls() => Profile(
    id: 'v1',
    protocol: Protocol.vless,
    name: 'v',
    address: 'nl1.example.net',
    port: 443,
    uuidOrPassword: '00000000-0000-0000-0000-000000000000',
    network: 'tcp',
    security: 'tls',
    sni: 'nl1.example.net',
  );

  Profile hy2({String obfs = ''}) => Profile(
    id: 'h1',
    protocol: Protocol.hysteria2,
    name: 'h',
    address: 'hy2.example.net',
    port: 443,
    uuidOrPassword: 'hy2-password',
    obfs: obfs,
    obfsPassword: 'obfs-pw',
    security: 'tls',
    sni: 'hy2.example.net',
  );

  Map<String, dynamic> tunnelOf(Profile p, XraySettings s) =>
      jsonDecode(buildTunnelConfig(p, s)) as Map<String, dynamic>;

  Map<String, dynamic> proxyOutOf(Map<String, dynamic> cfg) =>
      (cfg['outbounds'] as List).first as Map<String, dynamic>;

  group('build 2126 — D1 gecko packet sizes', () {
    Profile gecko() => parseLink(
      'hy2://pw@hy2.example.net:443?obfs=gecko&obfs-password=obfs-pw'
      '&geckoMinPacketSize=512&geckoMaxPacketSize=1200'
      '&sni=hy2.example.net#g',
    )!;

    test('the link band parses, under several spellings', () {
      final p = gecko();
      expect(p.geckoMinPacketSize, 512);
      expect(p.geckoMaxPacketSize, 1200);
      final alt = parseLink(
        'hy2://pw@hy2.example.net:443?obfs=gecko'
        '&minPacketSize=300&maxPacketSize=900#g',
      )!;
      expect(alt.geckoMinPacketSize, 300);
      expect(alt.geckoMaxPacketSize, 900);
    });

    test('codec and link generation keep the band', () {
      final p = gecko();
      final restored = Profile.fromJson(p.toJson());
      expect(restored.geckoMinPacketSize, 512);
      expect(restored.geckoMaxPacketSize, 1200);
      final link = profileToLink(p);
      expect(link, contains('geckoMinPacketSize=512'));
      expect(link, contains('geckoMaxPacketSize=1200'));
      expect(parseLink(link)!.geckoMinPacketSize, 512);
    });

    test('the sizes emit only under the toggle', () {
      final off = buildSingBoxConfig(gecko());
      final offObfs =
          (off['outbounds'] as List).single['obfs'] as Map<String, dynamic>;
      expect(offObfs, {'type': 'gecko', 'password': 'obfs-pw'});
      final on = buildSingBoxConfig(gecko(), geckoPacketSizes: true);
      final onObfs =
          (on['outbounds'] as List).single['obfs'] as Map<String, dynamic>;
      expect(onObfs, {
        'type': 'gecko',
        'password': 'obfs-pw',
        'min_packet_size': 512,
        'max_packet_size': 1200,
      });
    });
  });

  group('build 2126 — D2 fragment via FinalMask', () {
    test('ON: mask entry on the outbound, no frag chain or outbound', () {
      final s = XraySettings()
        ..fragmentEnabled = true
        ..fragmentViaFinalmask = true;
      final cfg = tunnelOf(vlessTls(), s);
      final out = proxyOutOf(cfg);
      final stream = out['streamSettings'] as Map<String, dynamic>;
      expect(stream['sockopt'], isNot(contains('dialerProxy')));
      final fm = stream['finalmask'] as Map<String, dynamic>;
      expect(fm['tcp'], [
        {
          'type': 'fragment',
          'settings': {
            'packets': 'tlshello',
            'lengths': ['100'],
            'delays': ['10'],
          },
        },
      ]);
      final tags = (cfg['outbounds'] as List).map((o) => (o as Map)['tag']);
      expect(tags, isNot(contains('frag')));
    });

    test('OFF: the 2125 chain, exactly', () {
      final s = XraySettings()..fragmentEnabled = true;
      final cfg = tunnelOf(vlessTls(), s);
      final out = proxyOutOf(cfg);
      final stream = out['streamSettings'] as Map<String, dynamic>;
      expect(stream['sockopt'], containsPair('dialerProxy', 'frag'));
      expect(stream.containsKey('finalmask'), isFalse);
      final tags = (cfg['outbounds'] as List).map((o) => (o as Map)['tag']);
      expect(tags, contains('frag'));
    });

    test('ON + profile noise: the frag outbound stays, fragment-free', () {
      final p = vlessTls()..afTcpNoise = true;
      final s = XraySettings()
        ..fragmentEnabled = true
        ..fragmentViaFinalmask = true;
      final cfg = tunnelOf(p, s);
      final frag = (cfg['outbounds'] as List).firstWhere(
        (o) => (o as Map)['tag'] == 'frag',
      ) as Map<String, dynamic>;
      final fragSettings = frag['settings'] as Map<String, dynamic>;
      expect(fragSettings.containsKey('fragment'), isFalse);
      expect(fragSettings, contains('noises'));
      final out = proxyOutOf(cfg);
      final stream = out['streamSettings'] as Map<String, dynamic>;
      expect(stream['sockopt'], containsPair('dialerProxy', 'frag'));
      expect(stream['finalmask'], isNotNull);
    });
  });

  group('build 2126 — D6 Hy2 noise decoy', () {
    test('ON: the noise mask leads the udp list', () {
      final s = XraySettings()..hy2NoiseDecoy = true;
      final out = proxyOutOf(tunnelOf(hy2(obfs: 'salamander'), s));
      final fm =
          (out['streamSettings'] as Map<String, dynamic>)['finalmask']
              as Map<String, dynamic>;
      final udp = fm['udp'] as List;
      expect(udp, hasLength(2));
      expect((udp[0] as Map)['type'], 'noise');
      expect((udp[1] as Map)['type'], 'salamander');
      final items =
          ((udp[0] as Map)['settings'] as Map<String, dynamic>)['noise']
              as List;
      expect(items, isNotEmpty);
      expect((items.first as Map), contains('rand'));
    });

    test('OFF: 2125 shapes — none on plain, salamander alone', () {
      final plain = proxyOutOf(tunnelOf(hy2(), XraySettings()));
      expect(
        (plain['streamSettings'] as Map<String, dynamic>).containsKey(
          'finalmask',
        ),
        isFalse,
      );
      final sal = proxyOutOf(tunnelOf(hy2(obfs: 'salamander'), XraySettings()));
      final udp =
          ((sal['streamSettings'] as Map<String, dynamic>)['finalmask']
                  as Map<String, dynamic>)['udp']
              as List;
      expect(udp, hasLength(1));
      expect((udp.single as Map)['type'], 'salamander');
    });
  });

  group('build 2126 — D7 randomized geometry', () {
    test('the z1r shape emits its ranges verbatim', () {
      final shape = afFragmentShapes.singleWhere((s) => s.id == 'z1r');
      expect(shape.entry(), {
        'type': 'fragment',
        'settings': {
          'packets': 'tlshello',
          'lengths': ['1-3', '2-4', '4-6', '6-10'],
          'delays': ['0-10'],
        },
      });
    });

    test('the fixed z1 shape is unchanged', () {
      final z1 = afFragmentShapes.singleWhere((s) => s.id == 'z1');
      expect(z1.lengths, ['2', '3', '5', '8']);
      expect(z1.delays, ['0']);
    });

    test('the feed validator accepts range delays', () {
      final body = jsonEncode({
        'version': 1,
        'strategies': [
          {
            'id': 'rand-geo',
            'label': 'Randomized geometry',
            'shape': {
              'fragment': {
                'lengths': ['1-3', '2-4'],
                'delays': ['0-10'],
              },
            },
          },
        ],
      });
      final parsed = parseDpiStrategyFeedBody(body);
      expect(parsed, hasLength(1));
      expect(parsed.single.fragment!.delays, ['0-10']);
    });
  });

  group('build 2126 — D8 sidecar TLS fragmentation', () {
    test('ON: the catch-all route-options rule is emitted', () {
      final cfg = buildSingBoxConfig(hy2(), sidecarTlsFragment: true);
      expect(cfg['route'], {
        'rules': [
          {'action': 'route-options', 'tls_fragment': true},
        ],
        'final': 'proxy',
      });
    });

    test('OFF: the 2125 route section, exactly', () {
      final cfg = buildSingBoxConfig(hy2());
      expect(cfg['route'], {'final': 'proxy'});
    });
  });

  group('build 2126 — D9 F-family Lab probes', () {
    test('each F candidate applies its editor shape', () {
      final p = vlessTls();
      const pairs = {
        'af-f2': 'f2',
        'af-f3': 'f3',
        'af-f6': 'f6',
        'af-f7': 'f7',
        'af-f8': 'f8',
        'af-f9': 'f9',
        'af-f13': 'f13',
        'af-f14': 'f14',
        'af-f15': 'f15',
        'af-z1r': 'z1r',
      };
      pairs.forEach((candidate, shape) {
        expect(
          profileWithCandidate(p, candidate).afFragment,
          shape,
          reason: candidate,
        );
      });
    });
  });
}
