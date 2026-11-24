// Build 2136 — the owner's approved 20, in order, plus the
// visual-review polish leg. This file pins what this build
// actually changed and re-verifies the items that turned out
// to be already shipped (7/10/13/17/20 — see
// build2136-progress.md for the per-item feasibility record
// and the parked items' evidence: 4/5/6, 11, 12, 15, 16,
// 18, 19).
//
//  - Item 1: stop-on-sleep (settings default OFF, Kotlin
//    ACTION_SCREEN_OFF receiver → channel → shell disconnect)
//    on top of the 2050 polling diet (2 s fg / 30 s bg).
//  - Item 2: already shipped in build 2105 (battery_report).
//  - Item 3: V-23 blur-off sweep + V-20 + V-21 (below).
//  - Item 8: randomized fragment geometry (ranges instead
//    of fixed cuts) behind a DEFAULT-OFF setting.
//  - Item 9: the full PORTABLE F-family is in the Lab —
//    pinned below; F4/F5 are runtime SNI-search recipes a
//    static config cannot express (anti_filter.dart header,
//    build 2026) and their intent is covered by zap-split
//    (SNI-relative cuts at runtime); F10/F11 have no source
//    recipes in the ported family.
//  - Item 13: pqv end-to-end — already pinned by
//    build2057_test.dart (F-M13); re-asserted here once.
//  - Item 14: auto-fastest group start (DEFAULT OFF).
//  - Polish: V-02/V-04/V-08/V-12/V-13/V-14/V-15/V-16/V-17/
//    V-24/V-25/V-30 source + behaviour pins.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/dpi_lab.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();
String _kotlin(String rel) => File(
  'android/app/src/main/kotlin/com/ralysnd/ember/$rel',
).readAsStringSync();

Profile _tlsProfile() => Profile(
  id: 't1',
  name: 'tls',
  protocol: Protocol.vless,
  address: 'example.com',
  port: 443,
  uuidOrPassword: '11111111-1111-1111-1111-111111111111',
  security: 'tls',
  sni: 'example.com',
);

void main() {
  group('settings defaults (standing law: every 2136 toggle OFF)', () {
    test('the three new toggles default OFF and round-trip', () {
      final s = XraySettings();
      expect(s.stopVpnOnSleep, isFalse);
      expect(s.fragmentRandomGeometry, isFalse);
      expect(s.autoFastestGroup, isFalse);
      s.stopVpnOnSleep = true;
      s.fragmentRandomGeometry = true;
      s.autoFastestGroup = true;
      final back = XraySettings.fromJson(s.toJson());
      expect(back.stopVpnOnSleep, isTrue);
      expect(back.fragmentRandomGeometry, isTrue);
      expect(back.autoFastestGroup, isTrue);
      // A pre-2136 store (no keys) keeps every default OFF.
      final old = XraySettings.fromJson(const {});
      expect(old.stopVpnOnSleep, isFalse);
      expect(old.fragmentRandomGeometry, isFalse);
      expect(old.autoFastestGroup, isFalse);
    });
  });

  group('item 1 — stop on sleep wiring', () {
    test('Kotlin forwards ACTION_SCREEN_OFF on the app channel', () {
      final kt = _kotlin('MainActivity.kt');
      expect(kt, contains('Intent.ACTION_SCREEN_OFF'));
      expect(kt, contains('invokeMethod("screenOff", null)'));
      expect(kt, contains('registerScreenOffReceiver()'));
    });
    test('Dart intake + shell action are wired to the setting', () {
      final net = _src('net/network_info.dart');
      expect(net, contains("call.method == 'screenOff'"));
      expect(net, contains('screenOffRequests'));
      final shell = _src('ui/ember/ember_shell.dart');
      expect(shell, contains('NetworkInfoService.screenOffRequests'));
      expect(shell, contains('settings.stopVpnOnSleep'));
    });
    test('the settings row exists with the honest limit in copy', () {
      final ui = _src('ui/ember/ember_settings.dart');
      expect(ui, contains('Stop VPN when the screen turns off'));
      expect(ui, contains('while the app'));
    });
  });

  group('item 2 — battery report already shipped (build 2105)', () {
    test('the report + its DEFAULT-OFF gate are in the tree', () {
      expect(File('lib/ui/ember/battery_report.dart').existsSync(), isTrue);
      final app = _src('app_settings.dart');
      expect(app, contains('batteryReportEnabled = false'));
    });
  });

  group('item 7 — sidecar TLS fragmentation already shipped (2126)', () {
    test('setting, builder rule and UI row all present, default OFF', () {
      expect(XraySettings().sidecarTlsFragment, isFalse);
      expect(_src('xray/singbox_config.dart'), contains('tls_fragment'));
      expect(
        _src('ui/ember/ember_settings.dart'),
        contains('TLS fragmentation (sing-box engine)'),
      );
    });
  });

  group('item 8 — randomized fragment geometry', () {
    test('OFF: the finalmask entry keeps the fixed values (2135)', () {
      final s = XraySettings()
        ..fragmentEnabled = true
        ..fragmentViaFinalmask = true;
      final out = buildOutbound(_tlsProfile(), s, fragment: true);
      final fm =
          (out!['streamSettings'] as Map)['finalmask'] as Map;
      final tcp = (fm['tcp'] as List).first as Map;
      final st = tcp['settings'] as Map;
      expect(st['lengths'], ['100']);
      expect(st['delays'], ['10']);
    });
    test('ON: lengths and delays become ranges around the values', () {
      final s = XraySettings()
        ..fragmentEnabled = true
        ..fragmentViaFinalmask = true
        ..fragmentRandomGeometry = true;
      final out = buildOutbound(_tlsProfile(), s, fragment: true);
      final fm =
          (out!['streamSettings'] as Map)['finalmask'] as Map;
      final tcp = (fm['tcp'] as List).first as Map;
      final st = tcp['settings'] as Map;
      expect(st['lengths'], ['50-200']);
      expect(st['delays'], ['5-20']);
    });
    test('the freedom chain takes the same treatment (source pin)', () {
      final cb = _src('xray/config_builder.dart');
      expect(cb, contains("'length': _fragmentLengthSpec(s)"));
      expect(cb, contains("'interval': _fragmentDelaySpec(s)"));
      final ui = _src('ui/ember/ember_settings.dart');
      expect(ui, contains('Randomized fragment geometry'));
    });
  });

  group('item 9 — the full portable F-family is in the Lab', () {
    test('every shipped shape except f12 has an af-* candidate; '
        'f12 rides the s1 candidate', () {
      final ids = dpiLabCandidatesFor(_tlsProfile()).map((c) => c.id).toSet();
      for (final shape in afFragmentShapes) {
        if (shape.id == 'mirage' || shape.id.startsWith('z')) continue;
        if (shape.id == 'f12') {
          expect(ids, contains('s1'));
        } else {
          expect(ids, contains('af-${shape.id}'), reason: shape.id);
        }
      }
    });
    test('F4/F5 stay absent (runtime SNI search — inexpressible '
        'in a static config) and zap-split covers their intent', () {
      final shapeIds = afFragmentShapes.map((s) => s.id).toSet();
      expect(shapeIds, isNot(contains('f4')));
      expect(shapeIds, isNot(contains('f5')));
      final ids = dpiLabCandidatesFor(_tlsProfile()).map((c) => c.id).toSet();
      expect(ids, contains('zap-split'));
    });
  });

  group('item 10 — gecko obfs already shipped (sidecar diversion)', () {
    test('the sing-box builder emits the profile obfs block', () {
      final sb = _src('xray/singbox_config.dart');
      expect(sb, contains("'type': p.obfs"));
      expect(sb, contains('gecko'));
    });
  });

  group('item 13 — REALITY pqv preserved end to end', () {
    test('link parse → profile → built reality settings → share', () {
      const link =
          'vless://11111111-1111-1111-1111-111111111111@[2001:db8::1]:443'
          '?security=reality&sni=example.com'
          '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          '&sid=abcd&fp=chrome&pqv=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB#PQ';
      final p = parseLink(link);
      expect(p, isNotNull);
      expect(p!.pqv, startsWith('BBBB'));
      final out = buildOutbound(p, XraySettings());
      final reality =
          (out!['streamSettings'] as Map)['realitySettings'] as Map;
      expect(reality['mldsa65Verify'], p.pqv);
      final back = parseLink(profileToLink(p));
      expect(back!.pqv, p.pqv);
    });
  });

  group('item 14 — auto-fastest group start', () {
    test('connect() consults the setting before the group walk', () {
      final c = _src('xray/xray_controller.dart');
      final at = c.indexOf('settings.autoFastestGroup');
      expect(at, greaterThan(0));
      final walkAt = c.indexOf('_connectWithFallbackGroup(allowGroupWalk');
      expect(at, lessThan(walkAt));
      expect(c, contains('Auto-fastest:'));
      expect(
        _src('ui/ember/ember_settings.dart'),
        contains('Auto-fastest group'),
      );
    });
  });

  group('item 17 — OpenConnect already shipped (build 2075)', () {
    test('protocol, parser and sidecar endpoint are in the tree', () {
      expect(
        _src('xray/link_parser.dart'),
        contains("link.startsWith('openconnect://')"),
      );
      expect(_src('xray/singbox_config.dart'), contains("'type': 'openconnect'"));
    });
  });

  group('item 20 — sandbox test already shipped (build 2061)', () {
    test('the isolated-core test + sheet exist', () {
      expect(File('lib/xray/sandbox_test.dart').existsSync(), isTrue);
      expect(
        File('lib/ui/ember/sandbox_test_sheet.dart').existsSync(),
        isTrue,
      );
    });
  });

  group('item 3 + polish leg — visual review fixes', () {
    test('V-23: MapSettingsPanel renders static glass', () {
      final mw = _src('ui/ember/map_widgets.dart');
      final at = mw.indexOf('class MapSettingsPanel');
      // PIN UPDATED by build 2145 (composition rebuild):
      // the panel's glass is retired entirely — the section
      // is an editorial hairline group (tracked orange
      // title, no fill, no filter). V-23's rule — no live
      // BackdropFilter per settings panel inside scroll
      // views — holds a fortiori: the panel renders no
      // MapGlass and no BackdropFilter at all.
      final panel = mw.substring(at, at + 1600);
      expect(panel, contains('Ember.microLabelOrange'));
      expect(panel, isNot(contains('MapGlass(')));
      expect(panel, isNot(contains('BackdropFilter')));
    });
    test('V-21: EmberHome listens per-mode, not to a 7-way merge', () {
      final home = _src('ui/ember/ember_home.dart');
      expect(home, isNot(contains('Listenable.merge([')));
      expect(home, contains('1 => xray'));
    });
    test('V-02 + V-24: radius split + Settings title', () {
      final th = _src('ui/ember/ember_theme.dart');
      expect(th, contains('radiusPanel = 20'));
      expect(th, contains('radiusBar = 24'));
      expect(th, contains('radiusButton = 10'));
      final st = _src('ui/ember/ember_settings.dart');
      // PIN UPDATED by build 2138 (visual review V-06): the
      // Settings title's 18 sp (V-24) is the scale's headline
      // step (17) now — the frozen scale has no 18.
      // PIN UPDATED by build 2144 (reskin): the title is
      // the samples' huge light hero word now (same
      // localized string, Ember.hero style).
      expect(st, contains('style: Ember.hero'));
    });
    test('V-04: both faint tokens lifted to AA-passing values', () {
      final th = _src('ui/ember/ember_theme.dart');
      // PIN UPDATED by build 2144 (reskin): both faints
      // neutralised to the samples' grey ramp at the same
      // AA-passing lightness steps.
      expect(th, contains('faint = Color(0xFF82828A)'));
      expect(th, contains('faint = Color(0xFF9C9CA2)'));
    });
    test('V-08: the ACTIVE pill wears dark text on the gradient', () {
      final mw = _src('ui/ember/map_widgets.dart');
      final at = mw.indexOf("'ACTIVE',");
      expect(
        mw.substring(at, at + 1400),
        contains('color: Color(0xFF1A1206)'),
      );
    });
    test('V-25: stock chrome wears the navy ramp', () {
      final app = _src('ui/app.dart');
      // PIN UPDATED by build 2144 (reskin): the chrome wears
      // the samples' near-black neutrals now — dialog/menu
      // card #101216, sheet surface #0C0D10, snackbar
      // cardSoft #17191E; the navy hexes are retired.
      expect(app, contains('0xFF101216'));
      expect(app, contains('0xFF0C0D10'));
      expect(app, contains('0xFF17191E'));
      expect(app, isNot(contains('0xFF1B1C22')));
      expect(app, isNot(contains('0xFF16233A')));
    });
    test('V-12/V-13/V-14/V-15/V-16/V-17/V-30 in ember_servers', () {
      final sv = _src('ui/ember/ember_servers.dart');
      // V-12: PIN UPDATED by build 2144 (reskin): the
      // card radius 20 + specular line are retired — the
      // subscription block is typographic, its slices
      // carry no fill or borders and the foot is the
      // block's plain closing gap.
      expect(sv, isNot(contains('top: const Radius.circular(20)')));
      expect(sv, isNot(contains('bottom: Radius.circular(20)')));
      expect(
        sv,
        contains('const SizedBox(height: 12, width: double.infinity)'),
      );
      // V-13: the flat row form + in-card plumbing.
      // PIN UPDATED by the build 2145 fix round (A10 widget
      // composition): the _rowFor method became the _RowFor
      // widget class; the in-card call keeps its shape.
      expect(sv, contains('this.flat = false'));
      // PIN UPDATED by batch 2 (fidelity rollout): the
      // inCard plumbing is RETIRED — every profile row wears
      // the flat hairline form now (the pro6-servers rows
      // carry no fill and no rim anywhere), so the call
      // carries no inCard argument; the flat form itself is
      // pinned at the row's construction ('flat: true').
      expect(sv, contains('profile: profile,\n    multiSelect: multiSelect,'));
      expect(sv, contains('flat: true,'));
      // V-14: prune behind the overflow menu on the card head.
      expect(sv, contains("if (v == 'prune') onPrune!();"));
      // V-15: the per-card summary line in dim.
      // PIN UPDATED by build 2138 (V-06): the 11 sp floor is
      // the scale's micro step — the literal became the
      // named constant; the size stands.
      expect(sv,
          contains('TextStyle(fontSize: Ember.fontMicro, color: MapUi.dim)'));
      // V-16: PIN UPDATED by build 2144 (reskin): the
      // rust protocol tag chip is retired — the protocol
      // rides the row's one grey monospace micro-line
      // with the host, per the pro6 servers sample.
      expect(sv, isNot(contains('Color(0xFF2E1610)')));
      expect(sv, isNot(contains('Color(0xFF7A321A)')));
      expect(sv, isNot(contains('Color(0xFFFFB59A)')));
      expect(sv, contains(r"'${profile.protocol.label} · '"));
      // V-17: the strip dot in the system green.
      expect(sv, contains('? Ember.green'));
      expect(sv, isNot(contains('0xFF4ADE80')));
      // V-30: group subtitle at the 11sp floor in dim.
      // PIN UPDATED by build 2138 (V-06): same re-point as
      // V-15 above — Ember.fontMicro is the 11 sp floor.
      expect(sv,
          contains('TextStyle(fontSize: Ember.fontMicro, color: MapUi.dim)'));
    });
  });
}
