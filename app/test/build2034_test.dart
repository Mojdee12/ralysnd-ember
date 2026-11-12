/// Build 2034 gates, host side: the Mozilla bootstrap choice
/// persists (and a stored value outside the picker is ignored),
/// the Mozilla page's status line says the honest thing in every
/// state, and the core status decodes the pass expiry + bootstrap
/// block the core reports (and tolerates their absence on an
/// older core). The handoff itself is native/device-side; its
/// evidence is the core's Go tests, the packaging gates and the
/// owner's device test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/models.dart';
import 'package:firefox_vpn/ui/ember/mozilla_bootstrap.dart';

void main() {
  group('bootstrap choice persistence', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('b2034_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('defaults to off', () async {
      final s = await AppSettings.load(dir.path);
      expect(s.mozillaBootstrap, 'off');
    });

    test('a picked donor survives a reload', () async {
      final s = await AppSettings.load(dir.path);
      s.update(mozillaBootstrap: 'psiphon');
      // update saves in the background.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final again = await AppSettings.load(dir.path);
      expect(again.mozillaBootstrap, 'psiphon');
    });

    test('a stored value outside the picker is ignored', () async {
      File('${dir.path}/app-settings.json').writeAsStringSync(
        '{"mozilla_bootstrap": "carrier-pigeon",'
        ' "ember_en_default": true, "welcome_done": true}',
      );
      final s = await AppSettings.load(dir.path);
      expect(s.mozillaBootstrap, 'off');
    });

    test('every picker choice is a valid stored value', () {
      expect(
        AppSettings.bootstrapChoices,
        ['off', 'psiphon', 'v2ray', 'warp', 'relay'],
      );
    });
  });

  group('donor names', () {
    test('map every choice', () {
      expect(MozillaBootstrap.donorName('off'), 'Off');
      expect(MozillaBootstrap.donorName('psiphon'), 'Psiphon');
      expect(MozillaBootstrap.donorName('v2ray'), 'V2Ray');
      expect(MozillaBootstrap.donorName('warp'), 'WARP');
      expect(MozillaBootstrap.donorName('relay'), 'Cloudflare relay');
      expect(MozillaBootstrap.donorName('???'), 'Off');
    });
  });

  group('status line', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final future = now.millisecondsSinceEpoch ~/ 1000 + 3600;
    final past = now.millisecondsSinceEpoch ~/ 1000 - 60;

    String line({
      String donor = 'off',
      bool connected = false,
      bool busy = false,
      String busyLabel = '',
      int passExpiresAt = 0,
    }) => MozillaBootstrap.statusLine(
      donor: donor,
      connected: connected,
      busy: busy,
      busyLabel: busyLabel,
      passExpiresAt: passExpiresAt,
      now: now,
    );

    test('busy wins and shows the live label', () {
      expect(
        line(busy: true, busyLabel: 'Bootstrap via Psiphon…'),
        'Bootstrap via Psiphon…',
      );
    });

    test('connected is Direct, whatever the donor', () {
      expect(line(donor: 'psiphon', connected: true), 'Direct');
    });

    test('an unexpired stored pass reads Pass ready', () {
      expect(line(donor: 'psiphon', passExpiresAt: future), 'Pass ready');
      expect(line(donor: 'off', passExpiresAt: future), 'Pass ready');
    });

    test('off with no usable pass is Direct', () {
      expect(line(passExpiresAt: past), 'Direct');
      expect(line(), 'Direct');
    });

    test('the relay choice names the relay', () {
      expect(
        line(donor: 'relay'),
        'Bootstrap via Cloudflare relay on next connect',
      );
    });

    test('engine donors name the engine', () {
      expect(line(donor: 'psiphon'), 'Bootstrap via Psiphon on next connect');
      expect(line(donor: 'v2ray'), 'Bootstrap via V2Ray on next connect');
      expect(line(donor: 'warp'), 'Bootstrap via WARP on next connect');
    });
  });

  group('core status decode', () {
    test('pass expiry + bootstrap block decode', () {
      final s = CoreStatus.fromJson({
        'state': {'phase': 'off'},
        'pass_expires_at': 1893456000,
        'bootstrap': {
          'egress': 'relay',
          'relay_url': 'https://relay.example.com',
          'relay_key_set': true,
        },
      });
      expect(s.passExpiresAt, 1893456000);
      expect(s.bootstrap, isNotNull);
      expect(s.bootstrap!.egress, 'relay');
      expect(s.bootstrap!.relayUrl, 'https://relay.example.com');
      expect(s.bootstrap!.relayKeySet, isTrue);
    });

    test('missing keys decode to no pass, no bootstrap', () {
      final s = CoreStatus.fromJson({
        'state': {'phase': 'off'},
      });
      expect(s.passExpiresAt, 0);
      expect(s.bootstrap, isNull);
    });
  });
}
