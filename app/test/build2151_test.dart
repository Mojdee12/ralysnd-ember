/// Build 2151 — the bridge-profile fix build.
///
///  - Item A (native): the tunlink bridge's gVisor stack
///    profile — receive-buffer autotuning ON and buffer
///    defaults raised via the engine Key, congestion
///    control cubic via a one-line vendored default
///    patch. The native pins live with the .so checks in
///    the build record; the Dart-side pins here guard the
///    source edits the coordinator made in native-src.
///  - Item B: the IPv6 session note's wording is
///    corrected to the platform truth (Android blocks
///    the unconfigured family for captured apps; the old
///    text claimed a leak that cannot happen).
///  - Item C: switchServer de-tripled — a failed
///    post-rotation proof no longer rolls back (a second
///    core rotation) or falls into a full reconnect (a
///    third); the switch stays on the new config,
///    stamped unverified.
///  - Item D: the connected-but-blocked alert — when an
///    adopted session's background proof never lands,
///    one plain ✗ journal line per session. Behind the
///    "Connected-but-blocked alert" Settings toggle,
///    DEFAULT ON by the owner's explicit order
///    (2026-11-26) — the one exception to the features
///    law's default-off rule.
///
/// The behavioural proof for the device-facing items is
/// the owner's device acceptance; these tests keep the
/// wiring from silently regressing out of the tree.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();
String nativeSrc(String rel) =>
    File('../../native-src/$rel').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('build 2151 — item B: the IPv6 note tells the truth', () {
    test('the note states the platform block, not a leak', () {
      final note = ipv6UncoveredSessionNote(XraySettings())!;
      expect(note, contains('This tunnel carries no IPv6'));
      expect(note, contains('blocks IPv6'));
      expect(note, contains('fall back to IPv4'));
      // The pre-2151 false claims are gone.
      expect(note, isNot(contains('keeps your current')));
      expect(note, isNot(contains('physical link')));
      expect(note, isNot(contains('stays outside')));
    });

    test('the note still fires only with the route off', () {
      expect(ipv6UncoveredSessionNote(XraySettings()), isNotNull);
      final on = XraySettings()..ipv6Route = true;
      expect(ipv6UncoveredSessionNote(on), isNull);
      // The default itself is unchanged (v2rayNG parity).
      expect(XraySettings().ipv6Route, isFalse);
    });
  });

  group('build 2151 — item D: connected-but-blocked alert', () {
    test('the toggle defaults ON (the owner-ordered exception)', () {
      expect(XraySettings().blockedAlert, isTrue);
    });

    test('the toggle round-trips through the settings JSON', () {
      final off = XraySettings()..blockedAlert = false;
      expect(off.toJson()['blockedAlert'], isFalse);
      final back = XraySettings.fromJson(off.toJson());
      expect(back.blockedAlert, isFalse);
      final on = XraySettings();
      expect(on.toJson()['blockedAlert'], isTrue);
      expect(XraySettings.fromJson(on.toJson()).blockedAlert, isTrue);
    });

    test('an absent stored key keeps the default ON', () {
      final j = XraySettings().toJson()..remove('blockedAlert');
      expect(XraySettings.fromJson(j).blockedAlert, isTrue);
    });

    test('toggle ON: exactly one alert line per session', () {
      final c = XrayController();
      expect(c.settings.blockedAlert, isTrue);
      c.journalBlockedAlert(4242);
      c.journalBlockedAlert(4242);
      c.journalBlockedAlert(4242);
      final alerts = c.diagnostics.entries
          .where((e) => e.text.contains('Connected but blocked'))
          .toList();
      expect(alerts, hasLength(1));
      expect(alerts.single.ok, isFalse);
      expect(alerts.single.source, 'connect');
      expect(
        alerts.single.text,
        contains('no traffic is getting through this config'),
      );
      // A new session (a new sinceMs) alerts again — once.
      c.journalBlockedAlert(5555);
      c.journalBlockedAlert(5555);
      expect(
        c.diagnostics.entries
            .where((e) => e.text.contains('Connected but blocked')),
        hasLength(2),
      );
    });

    test('toggle OFF: no alert line ever', () {
      final c = XrayController();
      c.settings.blockedAlert = false;
      c.journalBlockedAlert(4242);
      c.journalBlockedAlert(5555);
      expect(
        c.diagnostics.entries
            .where((e) => e.text.contains('Connected but blocked')),
        isEmpty,
      );
    });

    test('the alert is wired into the adoption-proof failure', () {
      final ctrl = dartSrc('xray/xray_controller.dart');
      final proofAt = ctrl.indexOf("stage: 'session proof'");
      expect(proofAt, greaterThan(0));
      final window = ctrl.substring(proofAt, proofAt + 1200);
      expect(window, contains('journalBlockedAlert(sinceMs);'));
      // The gate itself: the toggle and the per-session
      // latch both stand in front of the journal line.
      final gate = ctrl.substring(
        ctrl.indexOf('void journalBlockedAlert(int sinceMs)'),
        ctrl.indexOf('void journalBlockedAlert(int sinceMs)') + 700,
      );
      expect(gate, contains('if (!settings.blockedAlert) return;'));
      expect(gate, contains('_blockedAlertFor == sinceMs'));
    });

    test('the Settings row exists in the Xray section', () {
      final ui = dartSrc('ui/ember/ember_settings.dart');
      expect(ui, contains("label: 'Connected-but-blocked alert'"));
      expect(ui, contains('value: s.blockedAlert'));
    });
  });

  group('build 2151 — item C: the switch no longer triples', () {
    String switchBody() {
      final ctrl = dartSrc('xray/xray_controller.dart');
      final sw = ctrl.indexOf('Future<bool> switchServer(Profile next)');
      expect(sw, greaterThan(0));
      final end = ctrl.indexOf('\n  Future<', sw + 10);
      return ctrl.substring(sw, end < 0 ? sw + 16000 : end);
    }

    test('the rollback machinery is gone', () {
      final body = switchBody();
      // Code patterns, not the word: the build-2151
      // comments name rollbackSwitch while recording its
      // removal, so the pin targets the definition, the
      // call and the snapshot assignments.
      expect(body, isNot(contains('rollbackSwitch()')));
      expect(body, isNot(contains('await rollbackSwitch')));
      expect(body, isNot(contains('prevProfile =')));
      expect(body, isNot(contains('rolled back to')));
    });

    test('one rotation only: rotateConfig appears exactly once', () {
      final body = switchBody();
      expect('XrayPlatform.rotateConfig'.allMatches(body).length, 1);
    });

    test('a failed proof stays on the new config, unverified', () {
      final body = switchBody();
      final stayAt = body.indexOf('staying on this config, unverified');
      expect(stayAt, greaterThan(0));
      // The stay exit stamps the session unverified and
      // reports the switch as landed (return true), so no
      // caller runs a full reconnect on top of it.
      final window = body.substring(stayAt, stayAt + 400);
      expect(window, contains('return true;'));
      expect(body, contains('state = state.withVerified(false);'));
      // The old triple-restart journal wording is gone.
      expect(
        body,
        isNot(contains('but the new exit never answered; falling back')),
      );
    });

    test('the successful-switch path is untouched', () {
      final body = switchBody();
      expect(body, contains('Seamless switch to'));
      expect(body, contains('state = state.withVerified(true);'));
      expect(body, contains('_proofVerifiedSinceMs = state.sinceMs;'));
      expect(body, contains("'Switched to \${next.name} — connection kept.'"));
    });
  });

  group('build 2151 — item A: the bridge source profile', () {
    test('tunlink sets the engine Key stack options', () {
      final main = nativeSrc('tunlink/main.go');
      expect(main, contains('TCPModerateReceiveBuffer: true'));
      expect(main, contains('TCPSendBufferSize:'));
      expect(main, contains('TCPReceiveBufferSize:'));
      expect(main, contains('"4MB"'));
    });

    test('the vendored congestion-control default is cubic', () {
      final opt = nativeSrc('tun2socks/core/option/option.go');
      expect(opt, contains('tcpCongestionControlAlgorithm = "cubic"'));
      expect(opt, isNot(contains('tcpCongestionControlAlgorithm = "reno"')));
    });
  });

  group('build 2151 — version', () {
    test('pubspec carries 2.2.0+2154', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2156'),
      );
    });
  });
}
