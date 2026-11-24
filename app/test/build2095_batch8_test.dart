/// Build 2095, batch 8 gates — the long tail:
/// - #21 WarpProfile copy/absorb (edit-a-copy, commit on Save),
/// - batch-8 minor: Profile.lastSpeedBps persists,
/// - #29 EmberUpdater honours settings.autoUpdate for silent
///   checks (manual checks still run),
/// - §9 minor: a feed with no release reads as up-to-date,
///   not as an error.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/ui/ember/ember_updater.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

void main() {
  group('#21 WarpProfile copy/commit', () {
    test('editing a copy leaves the live profile untouched', () {
      final live = WarpProfile()
        ..protocol = 'wg'
        ..peer = '1.2.3.4:2408';
      final copy = live.copy()
        ..protocol = 'masque'
        ..peer = '';
      expect(live.protocol, 'wg');
      expect(live.peer, '1.2.3.4:2408');
      expect(copy.protocol, 'masque');
    });

    test('absorb commits every field', () {
      final live = WarpProfile();
      final edited = WarpProfile()
        ..protocol = 'gool'
        ..transport = 'h3'
        ..scan = 'random'
        ..ipVersion = 'v6'
        ..masqueSni = 'sni.example'
        ..fragment = false
        ..dns = '9.9.9.9'
        ..exitLoc = 'FRA'
        ..peer = '5.6.7.8:2408'
        ..obfuscation = 'quic'
        ..ech = true
        ..echDns = 'https://dns.example/dns-query'
        ..finalMask = '{"udp":["x"]}'
        ..dialMode = 'oob';
      live.absorb(edited);
      expect(live.toJson(), edited.toJson());
    });
  });

  group('lastSpeedBps persistence', () {
    test('round-trips; old JSON defaults to -1', () {
      final p = Profile(id: 'x', protocol: Protocol.vless)
        ..lastSpeedBps = 1234567;
      expect(Profile.fromJson(p.toJson()).lastSpeedBps, 1234567);
      expect(
        Profile.fromJson({'id': 'x', 'protocol': 'vless'}).lastSpeedBps,
        -1,
      );
    });
  });

  group('#29 updater honours autoUpdate', () {
    EmberUpdater make(AppSettings settings, {required bool feedEmpty}) {
      return EmberUpdater(
        settings: settings,
        dataDir: '/tmp',
        fetcher: (url) async {
          return feedEmpty
              ? jsonEncode({'message': 'Not Found'})
              : jsonEncode({
                  'tag_name': 'v9999',
                  'name': 'Build 9999',
                  'body': 'notes',
                  'assets': [
                    {
                      'name': 'RalysndEmber2.apk',
                      'browser_download_url': 'https://example.com/a.apk',
                      'size': 100,
                    },
                  ],
                });
        },
      )..addListener(() {});
    }

    test('silent check is a no-op when auto-update is off', () async {
      final settings = AppSettings()..autoUpdate = false;
      var fetches = 0;
      final u = EmberUpdater(
        settings: settings,
        dataDir: '/tmp',
        fetcher: (url) async {
          fetches++;
          return '{}';
        },
      );
      await u.check(manual: false);
      expect(fetches, 0);
      expect(u.state, EmberUpdateState.idle);
      // A manual check still runs.
      await u.check(manual: true);
      expect(fetches, 1);
    });

    test('a release-less feed reads as up-to-date, not error', () async {
      final settings = AppSettings()..autoUpdate = true;
      final u = make(settings, feedEmpty: true);
      await u.check(manual: true);
      expect(u.state, EmberUpdateState.upToDate);
      expect(u.errorText, isEmpty);
    });
  });
}
