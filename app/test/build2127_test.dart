// Build 2127 gates — THE HEAVY BUILD (owner orders
// 2026-11-21 04:45 / 04:59 / 05:42 / 05:43 / 05:52 /
// 06:09 / 06:30 / 06:36). Scope H1–H9; dispositions and
// evidence live in build2127-progress.md. What is pinned
// here, per item:
//
//   H1 Zapret desync in the Lab — LANDED. The ciadpi
//      command lines per candidate (never -I, never -Y),
//      the candidate set's Lab gating (TLS-shaped only,
//      TCP-only), the profile transform marker, and the
//      tunnel/test config chaining through the
//      zapret-underlay outbound. OFF (no marker) the
//      builders emit no trace of the proxy — the 2126
//      configs byte-for-byte. Native wiring is pinned by
//      source (ZapretCore.kt, the MainActivity channel
//      cases, the controller's sweep hooks / connect
//      start / switch reconcile / teardown stop).
//   H2 Sudoku — LANDED. The sidecar config grammar (the
//      fork's option/h_sudoku.go, host-proven by
//      `sudokubox check` + a two-instance loopback), the
//      plain-language profile errors, the settings gate
//      (DEFAULT OFF, persisted).
//   H3 Per-route SNI spoofing — LANDED. The rule model,
//      the route-options emission ahead of the D8
//      catch-all, and OFF/empty byte-identity of the
//      route section.
//   H4 Kill-switch Mozilla + WG legs — LANDED (native;
//      source pins only — the on-device hold is the
//      owner's verdict, not claimed here).
//   H5 Pre-TUN window — LANDED (native; source pins).
//   H6 Semver visibility (A26-21) — LANDED. Pure-semver
//      tags parse as visible-but-uncomparable offers;
//      vNNNN behaviour unchanged (build2075 pins hold).
//   H7 Icon/logo — LANDED (asset presence pins).
//   H8 Lantern Smart/VIP — LANDED via the owner-ordered
//      app-side registration fallback (the shipped
//      binary's driver has no private-server entry —
//      proven from its own flag set). Pinned: the tag
//      fallback order and the servers.json merge
//      discipline (backup once, atomic write,
//      replace-by-tag, unreadable file refused).
//      SUPERSEDED in build 2129 (leg 1): the gomobile swap
//      deletes the merge path — registration is the core's
//      own addServerManagerInstance API now. The tag order
//      pins below still hold verbatim; the merge tests are
//      re-pointed to the supersession, and the H8 binary
//      guard to the daemon's removal (build2129_lantern_test
//      carries the new surface's pins).
//   H9 Mozilla upstream sync — PARKED with the diff
//      findings (the trees are divergent forks; Ember's
//      renewal machinery is ahead of the on-disk
//      upstream in the focus area; upstream's newer
//      1.0.15–19 work rides a control-plane design
//      Ember's core does not have). core.aar untouched —
//      nothing to pin.
//
// Nothing here claims a device behaviour: the Zapret
// proxy carrying a real carrier's traffic, a Sudoku
// server answering, the kill-switch holds and the VIP
// server joining Lantern's pool are the owner's phone's
// verdicts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/lantern/lantern_private.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/lantern_import.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/sidecar_platform.dart';
import 'package:firefox_vpn/xray/singbox_config.dart';
import 'package:firefox_vpn/xray/sni_spoof.dart';
import 'package:firefox_vpn/xray/sudoku_config.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/zapret_args.dart';

String _dart(String rel) => File('lib/$rel').readAsStringSync();
String _kotlin(String rel) => File(
  'android/app/src/main/kotlin/com/ralysnd/ember/$rel',
).readAsStringSync();

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Profile _vlessTls({String network = 'tcp'}) => Profile(
  id: 'v1',
  protocol: Protocol.vless,
  name: 'v',
  address: 'nl1.example.net',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: network,
  security: 'tls',
  sni: 'nl1.example.net',
);

Profile _sudoku({String options = ''}) => Profile(
  id: 'sd1',
  protocol: Protocol.sudoku,
  name: 'sd',
  address: '203.0.113.9',
  port: 8389,
  uuidOrPassword: 'sudoku-key',
  sudokuOptions: options,
);

void main() {
  // ---- H1: Zapret desync in the Lab ------------------------------------

  group('build 2127 H1 — zapret command lines', () {
    test('the candidate set is the six proven strategies', () {
      expect(zapretCandidateIds, [
        'zap-split',
        'zap-tlsrec',
        'zap-fake',
        'zap-disorder',
        'zap-oob',
        'zap-disoob',
      ]);
      for (final id in zapretCandidateIds) {
        expect(isZapretCandidate(id), isTrue, reason: id);
      }
      expect(isZapretCandidate('af-z1'), isFalse);
      expect(isZapretCandidate('s0'), isFalse);
    });

    test('every command line listens on loopback :20864 and '
        'never carries the forbidden flags', () {
      for (final id in zapretCandidateIds) {
        final args = buildZapretArgs(id);
        expect(args.take(4), ['-i', '127.0.0.1', '-p', '20864'], reason: id);
        expect(args, isNot(contains('-I')), reason: id);
        expect(args, isNot(contains('--conn-ip')), reason: id);
        expect(args, isNot(contains('-Y')), reason: id);
        expect(args, isNot(contains('--drop-sack')), reason: id);
      }
      expect(zapretListenPort, 20864);
    });

    test('the per-candidate desync flags are the host-proven shapes', () {
      expect(buildZapretArgs('zap-split').skip(4), [
        '--split',
        '2+s',
        '--split',
        '5+s',
      ]);
      expect(buildZapretArgs('zap-tlsrec').skip(4), ['--tlsrec', '3+s']);
      expect(buildZapretArgs('zap-fake').skip(4), [
        '--fake',
        '-1',
        '--fake-sni',
        'www.google.com',
        '--ttl',
        '4',
      ]);
      expect(buildZapretArgs('zap-disorder').skip(4), ['--disorder', '2+s']);
      expect(buildZapretArgs('zap-oob').skip(4), ['--oob', '2+s']);
      expect(buildZapretArgs('zap-disoob').skip(4), ['--disoob', '2+s']);
    });

    test('a non-zap id throws instead of inventing flags', () {
      expect(() => buildZapretArgs('af-z1'), throwsArgumentError);
    });
  });

  group('build 2127 H1 — Lab gating and the transform', () {
    test('a TLS-shaped profile is offered all six zap candidates', () {
      final ids = dpiLabCandidatesFor(_vlessTls()).map((c) => c.id).toSet();
      for (final id in zapretCandidateIds) {
        expect(ids, contains(id), reason: id);
      }
    });

    test('zap candidates are TCP-only: a QUIC transport drops them', () {
      final ids = dpiLabCandidatesFor(
        _vlessTls(network: 'quic'),
      ).map((c) => c.id).toSet();
      for (final id in zapretCandidateIds) {
        expect(ids, isNot(contains(id)), reason: id);
      }
    });

    test('a zap candidate marks the copy; other candidates do not', () {
      final marked = profileWithCandidate(_vlessTls(), 'zap-fake');
      expect(marked.zapretStrategy, 'zap-fake');
      expect(
        profileWithCandidate(_vlessTls(), 'af-z1').zapretStrategy,
        isEmpty,
      );
      // The stored profile itself is never mutated by a transform.
      expect(_vlessTls().zapretStrategy, isEmpty);
      expect(Profile(id: 'x', protocol: Protocol.vless).zapretStrategy, '');
    });
  });

  group('build 2127 H1 — config chaining', () {
    test('the tunnel config chains the proxy outbound through '
        'the zapret underlay', () {
      final marked = profileWithCandidate(_vlessTls(), 'zap-split');
      final cfg = _decode(buildTunnelConfig(marked, XraySettings()));
      final outbounds = cfg['outbounds'] as List;
      final underlay = outbounds
          .cast<Map<String, dynamic>>()
          .where((o) => o['tag'] == 'zapret-underlay')
          .toList();
      expect(underlay, hasLength(1));
      expect(underlay.single['protocol'], 'socks');
      final servers =
          ((underlay.single['settings'] as Map)['servers'] as List).single
              as Map;
      expect(servers['address'], '127.0.0.1');
      expect(servers['port'], zapretListenPort);
      // The proxy outbound is chained: it names the underlay
      // as its dialer (the _chainThroughUnderlay shape).
      final proxy = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['tag'] == 'proxy');
      expect(jsonEncode(proxy), contains('zapret-underlay'));
    });

    test('the Lab test config chains the same way', () {
      final marked = profileWithCandidate(_vlessTls(), 'zap-oob');
      final cfg = _decode(buildTestConfig(marked, XraySettings()));
      final tags = (cfg['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(tags, contains('zapret-underlay'));
    });

    test('OFF identity: an unmarked profile builds the 2126 '
        'config — no zapret trace anywhere', () {
      final plain = buildTunnelConfig(_vlessTls(), XraySettings());
      expect(plain, isNot(contains('zapret')));
      final plainTest = buildTestConfig(_vlessTls(), XraySettings());
      expect(plainTest, isNot(contains('zapret')));
    });
  });

  group('build 2127 H1 — native + controller wiring (source pins)', () {
    test('ZapretCore.kt stages libzapret.so on port 20864', () {
      final kt = _kotlin('ZapretCore.kt');
      expect(kt, contains('"libzapret.so"'));
      expect(kt, contains('20864'));
      final lib = File(
        'android/app/src/main/jniLibs/arm64-v8a/libzapret.so',
      );
      expect(lib.existsSync(), isTrue);
      expect(lib.lengthSync(), 115528);
    });

    test('MainActivity serves the zapret channel cases', () {
      final ma = _kotlin('MainActivity.kt');
      expect(ma, contains('"zapretStart"'));
      expect(ma, contains('"zapretStop"'));
      expect(ma, contains('"zapretState"'));
      expect(ma, contains('ZapretCore.start'));
    });

    test('the controller starts, sweeps, reconciles and reaps '
        'the proxy', () {
      final c = _dart('xray/xray_controller.dart');
      // Sweep hooks into the discovery run.
      expect(c, contains('prepareCandidate: (candidateId) async'));
      expect(c, contains('releaseCandidate: (candidateId) async'));
      // Connect path: loud failure, beside the DNSCrypt start.
      expect(c, contains('_startZapretForConnect'));
      expect(c, contains("StateError('zapret-start')"));
      // Switch reconcile: a strategy mismatch refuses the
      // seamless rotation.
      expect(
        c,
        contains(
          'dialProfile.zapretStrategy != _sessionZapretStrategy',
        ),
      );
      // Teardown reaps the proxy with the sidecars.
      expect(c, contains('await ZapretPlatform.stop();'));
    });

    test('ZapretPlatform mirrors the sidecar channel shape', () {
      expect(ZapretPlatform.lastStartError, isEmpty);
      final src = _dart('xray/sidecar_platform.dart');
      expect(src, contains("invokeMethod<bool>('zapretStart'"));
      expect(src, contains("invokeMapMethod<String, dynamic>('zapretState')"));
    });
  });

  // ---- H2: Sudoku -------------------------------------------------------

  group('build 2127 H2 — Sudoku config + errors', () {
    test('the listen port is the free one', () {
      expect(sudokuListenPort, 20865);
    });

    test('a minimal profile emits exactly the required grammar', () {
      final cfg = buildSudokuConfig(_sudoku());
      final outbound = (cfg['outbounds'] as List).single as Map;
      expect(outbound, {
        'type': 'sudoku',
        'tag': 'proxy',
        'server': '203.0.113.9',
        'server_port': 8389,
        'key': 'sudoku-key',
      });
      final inbound = (cfg['inbounds'] as List).single as Map;
      expect(inbound['type'], 'mixed');
      expect(inbound['listen_port'], sudokuListenPort);
      expect((cfg['route'] as Map)['final'], 'proxy');
    });

    test('options ride through under the fork\u2019s own key names', () {
      final cfg = buildSudokuConfig(
        _sudoku(
          options: jsonEncode({
            'aeadMethod': 'chacha20-poly1305',
            'paddingMin': 4,
            'paddingMax': 64,
            'tableType': 'prefer_ascii',
            'pureDownlink': true,
            'httpMask': true,
            'httpMaskHost': 'cdn.example.com',
          }),
        ),
      );
      final outbound = (cfg['outbounds'] as List).single as Map;
      expect(outbound['aead_method'], 'chacha20-poly1305');
      expect(outbound['padding_min'], 4);
      expect(outbound['padding_max'], 64);
      expect(outbound['table_type'], 'prefer_ascii');
      expect(outbound['enable_pure_downlink'], isTrue);
      expect((outbound['http_mask'] as Map)['enabled'], isTrue);
      expect((outbound['http_mask'] as Map)['host'], 'cdn.example.com');
    });

    test('profile errors are plain and first-reason', () {
      expect(sudokuConfigError(_sudoku()), isNull);
      expect(
        sudokuConfigError(_vlessTls()),
        'not a Sudoku profile',
      );
      expect(
        sudokuConfigError(_sudoku()..address = ''),
        contains('server address'),
      );
      expect(
        sudokuConfigError(_sudoku()..uuidOrPassword = ''),
        contains('needs its key'),
      );
      expect(
        sudokuConfigError(
          _sudoku(options: jsonEncode({'aeadMethod': 'rot13'})),
        ),
        contains('AEAD method'),
      );
      expect(
        sudokuConfigError(
          _sudoku(options: jsonEncode({'tableType': 'bogus'})),
        ),
        contains('table type'),
      );
      expect(
        sudokuConfigError(
          _sudoku(
            options: jsonEncode({'paddingMin': 90, 'paddingMax': 10}),
          ),
        ),
        contains('padding minimum is above'),
      );
    });

    test('the share codec round-trips a Sudoku profile', () {
      final p = _sudoku(
        options: jsonEncode({'aeadMethod': 'aes-128-gcm'}),
      );
      final link = profileToLink(p);
      expect(link, startsWith('sudoku://'));
      final back = parseLink(link);
      expect(back, isNotNull);
      expect(back!.protocol, Protocol.sudoku);
      expect(back.address, p.address);
      expect(back.port, p.port);
      expect(back.uuidOrPassword, p.uuidOrPassword);
      expect(back.sudokuOpts['aeadMethod'], 'aes-128-gcm');
    });

    test('the engine gate defaults OFF and persists', () {
      expect(XraySettings().sudokuEnabled, isFalse);
      final s = XraySettings()..sudokuEnabled = true;
      final restored = XraySettings.fromJson(s.toJson());
      expect(restored.sudokuEnabled, isTrue);
      // A pre-2127 store has no key and reads as OFF.
      expect(XraySettings.fromJson(const {}).sudokuEnabled, isFalse);
    });
  });

  // ---- H3: per-route SNI spoofing ---------------------------------------

  group('build 2127 H3 — SNI spoof rules', () {
    Profile ss() => Profile(
      id: 'ss1',
      protocol: Protocol.shadowsocks,
      name: 'ss',
      address: '203.0.113.7',
      port: 8388,
      uuidOrPassword: 'ss-password',
      method: 'aes-128-gcm',
    );

    test('OFF identity: no rules ⇒ the 2126 route section exactly', () {
      final cfg = buildSingBoxConfig(ss());
      expect(cfg['route'], {'final': 'proxy'});
      final withEmpty = buildSingBoxConfig(ss(), sniSpoofRules: const []);
      expect(jsonEncode(withEmpty), jsonEncode(cfg));
    });

    test('rules emit route-options ahead of the D8 catch-all', () {
      final cfg = buildSingBoxConfig(
        ss(),
        sidecarTlsFragment: true,
        sniSpoofRules: [
          SniSpoofRule(
            id: 'r1',
            domain: 'example.com',
            spoof: 'cdn.example.net',
            method: 'wrong-checksum',
          ),
          SniSpoofRule(id: 'r2', domain: 'other.org', spoof: 'www.other.org'),
        ],
      );
      final rules = (cfg['route'] as Map)['rules'] as List;
      expect(rules, hasLength(3));
      expect(rules[0], {
        'action': 'route-options',
        'domain_suffix': ['example.com'],
        'tls_spoof': 'cdn.example.net',
        'tls_spoof_method': 'wrong-checksum',
      });
      // No method picked ⇒ no method key (the core default).
      expect(rules[1], {
        'action': 'route-options',
        'domain_suffix': ['other.org'],
        'tls_spoof': 'www.other.org',
      });
      expect(rules[2], {'action': 'route-options', 'tls_fragment': true});
      expect((cfg['route'] as Map)['final'], 'proxy');
    });

    test('a half-empty rule emits nothing', () {
      final cfg = buildSingBoxConfig(
        ss(),
        sniSpoofRules: [SniSpoofRule(id: 'r1', domain: '', spoof: 'x.net')],
      );
      expect(cfg['route'], {'final': 'proxy'});
    });

    test('the rule model is defensive and persists with the settings', () {
      expect(SniSpoofRule.fromJson('junk'), isNull);
      expect(SniSpoofRule.fromJson({'domain': 'a.com'}), isNull);
      final r = SniSpoofRule.fromJson({
        'id': 'r1',
        'domain': 'a.com',
        'spoof': 'b.net',
        'method': 'not-a-method',
      });
      expect(r, isNotNull);
      expect(r!.method, isEmpty); // unknown method reads as core default
      final s = XraySettings()
        ..sniSpoofEnabled = true
        ..sniSpoofRules = [
          SniSpoofRule(
            id: 'r1',
            domain: 'a.com',
            spoof: 'b.net',
            method: 'wrong-ack',
          ),
        ];
      expect(XraySettings().sniSpoofEnabled, isFalse);
      final restored = XraySettings.fromJson(s.toJson());
      expect(restored.sniSpoofEnabled, isTrue);
      expect(restored.sniSpoofRules, hasLength(1));
      expect(restored.sniSpoofRules.single.domain, 'a.com');
      expect(restored.sniSpoofRules.single.method, 'wrong-ack');
      expect(XraySettings.fromJson(const {}).sniSpoofRules, isEmpty);
    });
  });

  // ---- H6: semver release visibility ------------------------------------

  group('build 2127 H6 — semver tags are visible, never newer', () {
    test('semverFromReleaseTag accepts only pure semver', () {
      expect(semverFromReleaseTag('v2.3.0'), '2.3.0');
      expect(semverFromReleaseTag('2.3.0'), '2.3.0');
      expect(semverFromReleaseTag('v2.3.0-beta.1'), '2.3.0-beta.1');
      expect(semverFromReleaseTag('v2127'), isNull);
      expect(semverFromReleaseTag('v2.2.0+2127'), isNull);
      expect(semverFromReleaseTag('latest'), isNull);
      expect(semverFromReleaseTag('v2.3'), isNull);
    });

    Map<String, dynamic> feed(String tag) => {
      'tag_name': tag,
      'name': 'Ralysnd Ember',
      'assets': [
        {
          'name': 'RalysndEmber2.apk',
          'browser_download_url':
              'https://github.com/Mojdee12/ralysnd-ember/releases/download/$tag/RalysndEmber2.apk',
          'size': 123,
        },
      ],
    };

    test('a pure-semver release with the APK parses uncomparable', () {
      final r = parseLatestRelease(feed('v2.3.0'));
      expect(r, isNotNull);
      expect(r!.build, isNull);
      expect(r.uncomparable, isTrue);
      expect(r.isNewerThan(1), isFalse);
      expect(r.isNewerThan(99999), isFalse);
      expect(r.name, 'Ralysnd Ember');
    });

    test('a semver tag without the asset stays unusable', () {
      expect(parseLatestRelease({'tag_name': 'v2.3.0', 'assets': []}), isNull);
    });

    test('vNNNN behaviour is unchanged', () {
      final r = parseLatestRelease(feed('v2127'));
      expect(r!.build, 2127);
      expect(r.uncomparable, isFalse);
      expect(r.isNewerThan(2126), isTrue);
      expect(r.isNewerThan(2127), isFalse);
    });

    test('the newest pick prefers a numbered release over an '
        'uncomparable one', () {
      final picked = parseNewestRelease([
        feed('v9.9.9'),
        feed('v2127'),
      ]);
      expect(picked, isNotNull);
      expect(picked!.build, 2127);
      final onlySemver = parseNewestRelease([feed('v9.9.9')]);
      expect(onlySemver, isNotNull);
      expect(onlySemver!.uncomparable, isTrue);
    });
  });

  // ---- H8: Lantern VIP via app-side registration ------------------------

  group('build 2127 H8 — Lantern private-server registration', () {
    test('the tag falls back name → alias → ip', () {
      final named = parseLanternPrivateServerLink(
        'lantern://private-server?ip=203.0.113.5&port=8080&token=t&name=mine',
      );
      expect(named, isNotNull);
      expect(lanternPrivateTag(named!), 'mine');
      final bare = parseLanternPrivateServerLink(
        'lantern://private-server?ip=203.0.113.5&port=8080&token=t',
      );
      expect(bare, isNotNull);
      expect(lanternPrivateTag(bare!), '203.0.113.5');
    });

    test('the owner\u2019s key format parses verbatim', () {
      final link = parseLanternPrivateServerLink(
        'lantern://private-server?exp=1893456000&ip=203.0.113.5'
        '&port=8080&token=eyJhbGciOiJIUzI1NiJ9.payload.sig',
      );
      expect(link, isNotNull);
      expect(link!.ip, '203.0.113.5');
      expect(link.port, 8080);
      expect(link.token, startsWith('eyJ'));
    });

    test('SUPERSEDED in 2129: the servers.json merge path is '
        'deleted, registration is the core API', () {
      final privateDart = _dart('lantern/lantern_private.dart');
      expect(privateDart.contains('registerLanternPrivateServer'), isFalse);
      expect(privateDart.contains('servers.json'), isFalse);
      final controller = _dart('lantern/lantern_controller.dart');
      expect(controller.contains('LanternPlatform.addPrivateServer('), isTrue);
      expect(controller.contains('LanternPlatform.removePrivateServer('), isTrue);
    });
  });

  // ---- H4 / H5 / H7: native + asset pins --------------------------------

  group('build 2127 H4/H5/H7 — native legs and assets (source pins)', () {
    test('H4 Mozilla leg: the service retains a TUN dup and can '
        'hold the blackhole', () {
      final cs = _kotlin('CoreService.kt');
      expect(cs, contains('heldTun'));
      expect(cs, contains('ParcelFileDescriptor.dup'));
      expect(cs, contains('enterKillSwitchHold'));
      // The core binary is NOT rebound for this: H4 is
      // service-layer only (H9's park keeps it that way).
    });

    test('H4 WG leg: the tunnel library\u2019s own kill switch is wired', () {
      final wg = _kotlin('WgTunnelEngine.kt');
      expect(wg, contains('setKillSwitch'));
      expect(wg, contains('disableKillSwitch'));
      expect(wg, contains('KillSwitchConfig'));
    });

    test('H5: the Xray service can establish the blackhole TUN '
        'before the core proof', () {
      final xs = _kotlin('XrayVpnService.kt');
      expect(xs, contains('establishTun'));
      expect(xs, contains('keepTun'));
    });

    test('H7: the new icon set and in-app logo are in place', () {
      expect(File('assets/logo.png').existsSync(), isTrue);
      expect(
        File(
          'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png',
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
        ).existsSync(),
        isTrue,
      );
    });

    test('H8 guard SUPERSEDED in 2129: liblantern.so leaves '
        'the APK; the gomobile lib replaces it', () {
      expect(
        File('android/app/src/main/jniLibs/arm64-v8a/liblantern.so')
            .existsSync(),
        isFalse,
      );
      expect(
        File('android/app/src/main/jniLibs/arm64-v8a/liblantern_gojni.so')
            .existsSync(),
        isTrue,
      );
    });
  });
}
