// Build 2138 — the visual review's last two un-fixed
// items (scope frozen in build2138-progress.md):
//
//  1. V-06 (Low): ONE type scale — six frozen steps on
//     Ember (fontMicro 11 / fontSmall 12.5 / fontBody 13.5 /
//     fontTitle 15 / fontHeadline 17 / fontDisplay 21); the
//     named styles re-pointed onto them (heading 16→15,
//     body 14→13.5, dimStyle 13→13.5, caption 11.5→11) and
//     every literal fontSize in lib/ swept to the nearest
//     step. Recorded exceptions: the V-11 bottom bar's
//     10/10.5 sp (owner order 2083) and computed glyph
//     sizes (shield/badge/avatar/map painter).
//  2. V-26 (Low): pushed pages wear the converted header
//     treatment (profile_editor, build 2059): the body
//     extends behind a transparent AppBar and the first
//     content clears it by the status + toolbar inset.
//     41 of 45 appBar sites converted; recorded exceptions:
//     browser_signin (WebView body), qr scanner (camera
//     surface), the _emberPageRoute wrapper (its children
//     carry their own chrome / are shell-shared views).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/ember_info.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/licenses_page.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

Iterable<File> _libDart() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  group('V-06 type scale', () {
    test('the six steps are the frozen values', () {
      expect(Ember.fontMicro, 11);
      expect(Ember.fontSmall, 12.5);
      expect(Ember.fontBody, 13.5);
      expect(Ember.fontTitle, 15);
      expect(Ember.fontHeadline, 17);
      expect(Ember.fontDisplay, 21);
    });

    test('the named styles sit on the scale', () {
      expect(Ember.title.fontSize, Ember.fontDisplay);
      expect(Ember.heading.fontSize, Ember.fontTitle);
      expect(Ember.body.fontSize, Ember.fontBody);
      expect(Ember.dimStyle.fontSize, Ember.fontBody);
      expect(Ember.caption.fontSize, Ember.fontMicro);
    });

    test('no numeric fontSize literals remain off-scale in lib/', () {
      final literal = RegExp(r'fontSize:\s*[0-9]');
      final offenders = <String>[];
      for (final f in _libDart()) {
        final rel = f.path.replaceFirst('lib/', '');
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (literal.hasMatch(lines[i])) {
            offenders.add('$rel:${i + 1}');
          }
        }
      }
      // The only survivors are the V-11 bottom-bar exception
      // (10 / 10.5 / 10 in map_widgets.dart, owner order 2083).
      expect(offenders.length, 3);
      expect(
        offenders.every((o) => o.startsWith('ui/ember/map_widgets.dart:')),
        isTrue,
      );
    });

    test('the scale exceptions are recorded in the theme', () {
      final theme = _src('ui/ember/ember_theme.dart');
      expect(theme, contains('Type-scale exceptions (build 2138'));
      expect(theme, contains('fontMicro = 11'));
      expect(theme, contains('fontDisplay = 21'));
    });
  });

  group('V-26 pushed-page headers', () {
    test('every pushed page but the recorded exceptions extends '
        'behind its bar', () {
      var count = 0;
      for (final f in _libDart()) {
        count += 'extendBodyBehindAppBar: true'
            .allMatches(f.readAsStringSync())
            .length;
      }
      // 41 converted in this build + the profile_editor
      // exemplar from build 2059.
      // Build 2139 re-point: the new RegionHopPage is one
      // more converted site (the same pattern) → 43.
      // Build 2147 re-point: the shared _pageShell of the
      // three new Iran-feature pages is one more → 44.
      // Build 2149 re-point: the two new pushed pages —
      // the Daily problem report (expansion 4) and the
      // DNS preset picker (expansion 5) — follow the same
      // pattern → 46.
      // Build 2154 re-point: the new URnetworkPage follows
      // the same pattern → 47.
      // Build 2156 re-point: the UR engine's two pushed
      // pages (engine settings + logs) follow the same
      // pattern → 49.
      expect(count, 49);
      expect(_src('ui/browser_signin_page.dart'),
          isNot(contains('extendBodyBehindAppBar')));
      expect(_src('ui/ember/qr_pages.dart'),
          isNot(contains('extendBodyBehindAppBar')));
      expect(_src('ui/ember/ember_settings.dart'),
          isNot(contains('extendBodyBehindAppBar')));
    });

    testWidgets('LicensesPage: transparent bar over the backdrop, '
        'list clears it', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: LicensesPage()),
      );
      await tester.pump();
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.extendBodyBehindAppBar, isTrue);
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.backgroundColor, Colors.transparent);
      expect(bar.elevation, 0);
      expect(bar.foregroundColor, Ember.text);
      final list = tester.widget<ListView>(find.byType(ListView).first);
      final padding = list.padding! as EdgeInsets;
      // status inset (0 in the test view) + toolbar + the
      // page's own 6 dp top gap.
      expect(padding.top, kToolbarHeight + 6);
    });

    test('pubspec is 2.2.0+2148', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2157'),
      );
    });

    testWidgets('EmberInfoPage: same treatment, own top gap kept',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const EmberInfoPage(),
        ),
      );
      await tester.pump();
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.extendBodyBehindAppBar, isTrue);
      final list = tester.widget<ListView>(find.byType(ListView).first);
      final padding = list.padding! as EdgeInsets;
      expect(padding.top, kToolbarHeight + 14);
    });
  });
}
