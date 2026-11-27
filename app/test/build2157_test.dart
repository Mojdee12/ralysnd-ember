/// Build 2157 — the owner's feature picks (the first 4 of
/// the 2026-11-27 feature watch).
///
/// 1. OpenVPN LINK import: .ovpn files were already
///    importable (picker/paste/open-with); ovpn:// and
///    openvpn:// links were not — no manifest scheme and
///    no route in the deep-link intake. Now: the schemes
///    are declared, a pure parser reads the payload form
///    (base64 / URL-encoded / raw) and the official
///    import-profile form (https fetch only), and the
///    shell routes such links to the OpenVPN importer.
/// 2. The "Not secure" badge: a pure rule on Profile
///    (plain HTTP/SOCKS without TLS, Shadowsocks with
///    the none method) + the config row's red mark.
///    Display-only.
/// 3. The one-tap problem report on the 2149 machinery:
///    a pure composer (header + 7-day counts + crashes +
///    today's digest) and the 10-minute detailed-logging
///    window (persisted state, debug log level, forced
///    recording, restored at the end).
/// 4. The ByeDPI desync hop: settings.byedpiHop (DEFAULT
///    OFF) stamps the dial copy with a ciadpi strategy at
///    connect/switch — the Lab's zap machinery, picked by
///    hand. Profile.zapretStrategy stays runtime-only.
///
/// These tests pin the pure logic and the wiring. The
/// behavioural proof is the owner's device acceptance;
/// nothing here claims traffic flows.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/openvpn/ovpn_link.dart';
import 'package:firefox_vpn/xray/problem_report.dart';
import 'package:firefox_vpn/xray/xray_models.dart';
import 'package:firefox_vpn/xray/zapret_args.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String kotlinSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

const _ovpnFixture = '''
client
dev tun
proto udp
remote vpn.example.net 1194
resolv-retry infinite
nobind
<ca>
-----BEGIN CERTIFICATE-----
MIIFIXTURE
-----END CERTIFICATE-----
</ca>
''';

Profile _profile({
  required Protocol protocol,
  String security = '',
  String method = '',
}) => Profile(
  id: 'p1',
  name: 'Test',
  protocol: protocol,
  address: 'proxy.example.net',
  port: 1080,
  security: security,
  method: method,
);

void main() {
  group('build 2157 — version', () {
    test('pubspec is 2.2.0+2157', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2157'),
      );
    });
  });

  group('build 2157 — item 2: the Not secure rule', () {
    test('plain HTTP and SOCKS proxies are insecure', () {
      expect(_profile(protocol: Protocol.http).isInsecureProxy, isTrue);
      expect(
        _profile(protocol: Protocol.http).insecureProxyReason,
        contains('HTTP'),
      );
      expect(_profile(protocol: Protocol.socks).isInsecureProxy, isTrue);
      expect(
        _profile(protocol: Protocol.socks).insecureProxyReason,
        contains('SOCKS'),
      );
    });

    test('a TLS wrap takes HTTP/SOCKS out of the set', () {
      expect(
        _profile(protocol: Protocol.http, security: 'tls').isInsecureProxy,
        isFalse,
      );
      expect(
        _profile(protocol: Protocol.socks, security: 'tls').isInsecureProxy,
        isFalse,
      );
    });

    test('Shadowsocks is insecure only with no cipher', () {
      expect(
        _profile(protocol: Protocol.shadowsocks, method: 'none')
            .isInsecureProxy,
        isTrue,
      );
      expect(
        _profile(protocol: Protocol.shadowsocks, method: 'NONE')
            .isInsecureProxy,
        isTrue,
      );
      expect(
        _profile(protocol: Protocol.shadowsocks).isInsecureProxy,
        isTrue,
        reason: 'an empty method is the core default of none',
      );
      expect(
        _profile(protocol: Protocol.shadowsocks, method: 'aes-256-gcm')
            .isInsecureProxy,
        isFalse,
      );
      expect(
        _profile(protocol: Protocol.shadowsocks, method: 'chacha20-poly1305')
            .isInsecureProxy,
        isFalse,
      );
    });

    test('protocols with their own cryptography are never marked', () {
      for (final proto in [
        Protocol.vless,
        Protocol.vmess,
        Protocol.trojan,
        Protocol.wireguard,
        Protocol.hysteria2,
        Protocol.tuic,
        Protocol.anytls,
      ]) {
        expect(
          _profile(protocol: proto).isInsecureProxy,
          isFalse,
          reason: '$proto must not be marked',
        );
      }
    });

    test('the config row renders the badge from the rule', () {
      final src = dartSrc('ui/ember/ember_servers.dart');
      expect(src, contains('profile.isInsecureProxy'));
      expect(src, contains("'Not secure'"));
      expect(src, contains('Icons.lock_open_rounded'));
    });
  });

  group('build 2157 — item 1: ovpn:// links', () {
    test('the scheme gate', () {
      expect(isOvpnLink('ovpn://abc'), isTrue);
      expect(isOvpnLink('openvpn://import-profile/https://x'), isTrue);
      expect(isOvpnLink('OVPN://abc'), isTrue);
      expect(isOvpnLink('vless://abc'), isFalse);
      expect(isOvpnLink('https://example.net/p.ovpn'), isFalse);
    });

    test('the profile-text gate', () {
      expect(isOvpnProfileText(_ovpnFixture), isTrue);
      expect(
        isOvpnProfileText('[Interface]\nPrivateKey = x\n[Peer]\n'),
        isFalse,
      );
      expect(isOvpnProfileText('just some words'), isFalse);
    });

    test('a base64 payload link decodes to the profile', () {
      final b64 = base64Encode(utf8.encode(_ovpnFixture));
      final payload = parseOvpnLink('ovpn://$b64');
      expect(payload, isA<OvpnLinkText>());
      expect((payload! as OvpnLinkText).text, _ovpnFixture);
      expect(payload.name, '');
    });

    test('a base64 payload link carries its #name', () {
      final b64 = base64Encode(utf8.encode(_ovpnFixture));
      final payload = parseOvpnLink('ovpn://$b64#My%20Server');
      expect(payload, isA<OvpnLinkText>());
      expect(payload!.name, 'My Server');
    });

    test('a URL-encoded payload link decodes', () {
      final encoded = Uri.encodeComponent(_ovpnFixture);
      final payload = parseOvpnLink('ovpn://$encoded');
      expect(payload, isA<OvpnLinkText>());
      expect((payload! as OvpnLinkText).text, _ovpnFixture);
    });

    test('the official import-profile form is a fetch', () {
      final payload = parseOvpnLink(
        'openvpn://import-profile/https://as.example.net/rest/'
        'GetProfileViaToken?token=abc123#Work',
      );
      expect(payload, isA<OvpnLinkFetch>());
      final fetch = payload! as OvpnLinkFetch;
      expect(
        fetch.url,
        'https://as.example.net/rest/GetProfileViaToken?token=abc123',
      );
      expect(fetch.name, 'Work');
    });

    test('the import-profile ?url= form is a fetch', () {
      final inner = Uri.encodeComponent('https://vpn.example.net/p.ovpn');
      final payload = parseOvpnLink('ovpn://import-profile?url=$inner');
      expect(payload, isA<OvpnLinkFetch>());
      expect((payload! as OvpnLinkFetch).url, 'https://vpn.example.net/p.ovpn');
    });

    test('a bare profile URL under the scheme is a fetch', () {
      final payload = parseOvpnLink('ovpn://https://example.net/p.ovpn');
      expect(payload, isA<OvpnLinkFetch>());
      expect((payload! as OvpnLinkFetch).url, 'https://example.net/p.ovpn');
    });

    test('cleartext and garbage are refused', () {
      expect(
        parseOvpnLink('openvpn://import-profile/http://x.example.net/p'),
        isNull,
      );
      expect(parseOvpnLink('ovpn://'), isNull);
      expect(parseOvpnLink('ovpn://not-a-profile'), isNull);
      expect(parseOvpnLink('vless://uuid@example.net:443'), isNull);
    });

    test('the manifest declares both schemes', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('<data android:scheme="ovpn" />'));
      expect(manifest, contains('<data android:scheme="openvpn" />'));
    });

    test('the shell routes ovpn links before the generic parser', () {
      final src = dartSrc('ui/ember/ember_shell.dart');
      expect(src, contains('if (isOvpnLink(link))'));
      expect(src, contains('_importOvpnLink(link)'));
      expect(src, contains('fetchOvpnProfileText(url)'));
    });
  });

  group('build 2157 — item 3: the one-tap report', () {
    ProblemEvent ev(int atMs, String type, {String reason = 'code-x'}) =>
        ProblemEvent(
          atMs: atMs,
          type: type,
          engine: 'V2Ray',
          profileName: 'Home',
          shape: 'VLESS · tcp+tls',
          stage: 'dial',
          reason: reason,
        );

    test('an empty journal still composes a report', () {
      final now = DateTime(2026, 11, 27, 9, 30);
      final text = oneTapReportText(
        ProblemJournal(),
        now: now,
        appLine: 'App 2.2.0 (build 2157)',
      );
      expect(text, contains('Ember problem report — 2026-11-27'));
      expect(text, contains('App 2.2.0 (build 2157)'));
      expect(text, contains('No problems recorded in the last 7 days.'));
      expect(text, contains('No problems recorded today.'));
    });

    test('counts, crashes and the digest compose', () {
      final now = DateTime(2026, 11, 27, 9, 30);
      final twoDaysAgo = DateTime(2026, 11, 25, 22, 15);
      final journal = ProblemJournal([
        ev(now.millisecondsSinceEpoch, ProblemTypes.connectFailure),
        ev(
          twoDaysAgo.millisecondsSinceEpoch,
          ProblemTypes.previousSessionCrash,
          reason: 'the previous session ended without a clean disconnect',
        ),
      ]);
      final text = oneTapReportText(
        journal,
        now: now,
        appLine: 'App 2.2.0 (build 2157)',
      );
      expect(text, contains('Problems in the last 7 days: 2'));
      expect(text, contains('2026-11-25: 1'));
      expect(text, contains('2026-11-27: 1'));
      expect(text, contains('— crashes (last 7 days) —'));
      expect(text, contains('the previous session ended'));
      // Today's digest rides along unchanged.
      expect(text, contains('Connect failure: 1'));
      expect(text, contains('Ember daily problem report — 2026-11-27'));
    });

    test('the report carries no endpoint the journal never held', () {
      final now = DateTime(2026, 11, 27, 9, 30);
      final journal = ProblemJournal([
        ev(now.millisecondsSinceEpoch, ProblemTypes.dnsFailure),
      ]);
      final text = oneTapReportText(
        journal,
        now: now,
        appLine: 'App 2.2.0 (build 2157)',
      );
      expect(text, isNot(contains('example.net')));
      expect(text, isNot(contains('://')));
    });

    test('the window state round-trips through settings JSON', () {
      final s = XraySettings();
      expect(s.detailedLogUntilMs, 0);
      expect(s.detailedLogPrevLogLevel, '');
      s.detailedLogUntilMs = 123456789;
      s.detailedLogPrevLogLevel = 'warning';
      final back = XraySettings.fromJson(s.toJson());
      expect(back.detailedLogUntilMs, 123456789);
      expect(back.detailedLogPrevLogLevel, 'warning');
    });

    test('the window wiring is pinned', () {
      final controller = dartSrc('xray/xray_controller.dart');
      expect(controller, contains('Future<void> startDetailedLogging()'));
      expect(controller, contains("settings.logLevel = 'debug'"));
      expect(controller, contains('detailedLogWindow.inMilliseconds'));
      expect(controller, contains('_problemRecordingActive'));
      expect(controller, contains('_detailedLogTimer?.cancel()'));
      final page = dartSrc('ui/ember/daily_report_page.dart');
      expect(page, contains("'Send problem report'"));
      expect(page, contains('oneTapReportText('));
      expect(page, contains("'Collect detailed logs for 10 minutes'"));
    });
  });

  group('build 2157 — item 4: the ByeDPI hop', () {
    test('the hop defaults OFF and round-trips', () {
      final s = XraySettings();
      expect(s.byedpiHop, '');
      s.byedpiHop = 'zap-fake';
      expect(XraySettings.fromJson(s.toJson()).byedpiHop, 'zap-fake');
    });

    test('a corrupt stored hop reads as OFF', () {
      final j = XraySettings().toJson();
      j['byedpiHop'] = 'zap-bogus';
      expect(XraySettings.fromJson(j).byedpiHop, '');
      j['byedpiHop'] = 42;
      expect(XraySettings.fromJson(j).byedpiHop, '');
    });

    test('every strategy has a picker label', () {
      expect(zapretStrategyLabels.keys.toSet(), zapretCandidateIds.toSet());
      for (final id in zapretCandidateIds) {
        expect(zapretStrategyLabels[id], isNotEmpty);
        expect(buildZapretArgs(id).first, '-i');
      }
    });

    test('the stored profile still never carries the strategy', () {
      final p = _profile(protocol: Protocol.vless)..zapretStrategy = 'zap-oob';
      expect(p.toJson().containsKey('zapretStrategy'), isFalse);
      expect(Profile.fromJson(p.toJson()).zapretStrategy, '');
      // copy() drops it too — the funnel stamps a copy.
      expect(p.copy().zapretStrategy, '');
    });

    test('the funnel, switch, watchdog and setter are wired', () {
      final controller = dartSrc('xray/xray_controller.dart');
      expect(controller, contains('Future<void> setByedpiHop(String value)'));
      // The stamp appears at connect AND at switch.
      expect(
        '..zapretStrategy = settings.byedpiHop'
            .allMatches(controller)
            .length,
        2,
      );
      expect(controller, contains('_hopDialActive = true'));
      expect(controller, contains('does not ride the desync hop'));
      expect(controller, contains('_hopStandDownJournaled'));
    });

    test('the Settings picker exists; the chain list is untouched', () {
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, contains("'ByeDPI desync hop'"));
      expect(settings, contains('xray.setByedpiHop(id)'));
      // byedpi is NOT an underlay: the chain machinery's
      // list drives setUnderlay, a different axis.
      final chain = dartSrc('ui/ember/chain_builder_page.dart');
      expect(chain, contains("const chainUnderlays = ['warp', 'psiphon', 'dnstt', 'olcrtc']"));
    });
  });

  group('item 5 — URnetwork engine connect fix (diagnosis 2026-11-27)', () {
    // Both gaps are in UrVpnService.kt; the diagnosis
    // (urnetwork-engine-diagnosis-2026-11-27.md) proved
    // them from source against the SDK and the official
    // app. These pins hold the corrected shapes.

    test('Gap 1: establishTun excludes Ember from its own TUN', () {
      final service = kotlinSrc('UrVpnService.kt');
      final tun = service.substring(
        service.indexOf('private fun establishTun'),
        service.indexOf('private fun loadOrMintInstanceId'),
      );
      // The SDK has no protect() bridge: without the
      // self-exclusion its own egress is captured by the
      // TUN and the connect grid blackholes ("waiting for
      // a provider" forever).
      expect(
        tun,
        contains('builder.addDisallowedApplication(packageName)'),
      );
      // Exactly one exclusion site, inside establishTun,
      // before establish() runs.
      expect(
        'addDisallowedApplication(packageName)'
            .allMatches(service)
            .length,
        1,
      );
      expect(
        tun.indexOf('addDisallowedApplication(packageName)'),
        lessThan(tun.indexOf('builder.establish()')),
      );
    });

    test('Gap 2: a country pick selects through ConnectLocationId', () {
      final service = kotlinSrc('UrVpnService.kt');
      // The selector: the picked row's location_id goes
      // into ConnectLocationId.locationId, which is what
      // the SDK builds provider specs from. A null
      // ConnectLocationId is rejected as invalid.
      expect(
        service,
        contains('id.locationId = Sdk.parseId(locationId)'),
      );
      expect(service, contains('loc.connectLocationId = id'));
      // The country fields stay — as display metadata.
      expect(
        service,
        contains('loc.countryLocationId = Sdk.parseId(locationId)'),
      );
      // The Best Available shape is unchanged.
      expect(service, contains('id.bestAvailable = true'));
    });
  });
}
