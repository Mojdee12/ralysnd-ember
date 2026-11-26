/// Build 2152 gates, host side — DART-1 + DART-2 (the
/// Dart half of the Mozilla renewal fix):
///
/// - DART-1: the connect-time freshness floor rises from
///   60 s to 5 minutes. ONE pure predicate,
///   MozillaBootstrap.passFreshEnough, is consulted by
///   both passReady (the gate) and statusLine (the copy),
///   so the two can never disagree (the disagreement the
///   build 2098 note in statusLine records). The core's
///   renewal loop fires at exp − 2 min, so a session must
///   not start on a pass with less than that lead plus
///   working room.
/// - DART-1 (force): prepareIfNeeded gains {bool force} —
///   the manual Prepare entry points (the card's "Prepare
///   now", the Settings Guardian-pass row) call it with
///   force: true, since their copy already promises a
///   refresh; the connect toggle keeps the gated call;
///   donor 'off' still proceeds at once even forced.
/// - DART-2: when the connect path runs a handoff because
///   the stored pass was below the floor, the shell
///   journals one plain line through core.journalLine
///   (the producer the pass-boundary lines use, wired to
///   the diagnostics journal as source 'mozilla').
///
/// The handoff itself is native/device-side; the owner's
/// device verdict is the acceptance for the behaviour.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/mozilla_bootstrap.dart';

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

void main() {
  group('build 2152 — DART-1: the freshness predicate', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;

    test('the margin is five minutes', () {
      expect(
        MozillaBootstrap.freshPassMargin,
        const Duration(minutes: 5),
      );
    });

    test('4:59 of life left is not fresh', () {
      expect(
        MozillaBootstrap.passFreshEnough(nowSec + 299, now),
        isFalse,
      );
    });

    test('5:00 of life left is fresh', () {
      expect(
        MozillaBootstrap.passFreshEnough(nowSec + 300, now),
        isTrue,
      );
    });

    test('an expired pass is not fresh', () {
      expect(
        MozillaBootstrap.passFreshEnough(nowSec - 1, now),
        isFalse,
      );
      expect(MozillaBootstrap.passFreshEnough(0, now), isFalse);
    });

    test('well above the floor is fresh', () {
      expect(
        MozillaBootstrap.passFreshEnough(nowSec + 3600, now),
        isTrue,
      );
    });
  });

  group('build 2152 — DART-1: statusLine at the new floor', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;

    String line({
      String donor = 'psiphon',
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

    test('above the floor reads Pass ready', () {
      expect(line(passExpiresAt: nowSec + 300), 'Pass ready');
      expect(line(passExpiresAt: nowSec + 3600), 'Pass ready');
    });

    test('below the floor with a donor names the bootstrap', () {
      expect(
        line(passExpiresAt: nowSec + 299),
        'Bootstrap via Psiphon on next connect',
      );
      expect(
        line(donor: 'relay', passExpiresAt: nowSec + 60),
        'Bootstrap via Cloudflare relay on next connect',
      );
      expect(
        line(passExpiresAt: nowSec - 60),
        'Bootstrap via Psiphon on next connect',
      );
    });

    test('connected and busy branches are unchanged', () {
      expect(
        line(connected: true, passExpiresAt: nowSec + 60),
        'Direct',
      );
      expect(
        line(busy: true, busyLabel: 'Bootstrap via Psiphon…'),
        'Bootstrap via Psiphon…',
      );
    });

    test('gate and copy consult the one shared predicate', () {
      final bootstrap = dartSrc('ui/ember/mozilla_bootstrap.dart');
      // passReady delegates to the predicate…
      expect(
        bootstrap,
        contains(
          'bool get passReady =>\n'
          '      passFreshEnough(core.status?.passExpiresAt ?? 0, DateTime.now());',
        ),
      );
      // …and so does statusLine.
      expect(bootstrap, contains('if (passFreshEnough(passExpiresAt, now))'));
      // The pre-2152 duplicated 60 s thresholds are gone.
      expect(bootstrap, isNot(contains('+ 60000')));
    });
  });

  group('build 2152 — DART-1: the force wiring', () {
    test('prepareIfNeeded gates on force, donor off still proceeds', () {
      final bootstrap = dartSrc('ui/ember/mozilla_bootstrap.dart');
      expect(
        bootstrap,
        contains('Future<BootstrapVerdict> prepareIfNeeded({bool force = false})'),
      );
      expect(
        bootstrap,
        contains("if (donor == 'off' || (!force && passReady))"),
      );
    });

    test('the two manual Prepare sites call with force: true', () {
      final bootstrap = dartSrc('ui/ember/mozilla_bootstrap.dart');
      expect(
        bootstrap,
        contains(
          'final verdict = await _b.prepareIfNeeded(\n'
          '                            force: true,',
        ),
      );
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(
        settings,
        contains(
          'final verdict = await b.prepareIfNeeded(\n'
          '                                  force: true,',
        ),
      );
    });

    test('the connect toggle keeps the default gated call', () {
      final shell = dartSrc('ui/ember/ember_shell.dart');
      expect(
        shell,
        contains('final verdict = await _bootstrap.prepareIfNeeded();'),
      );
      expect(shell, isNot(contains('_bootstrap.prepareIfNeeded(force')));
    });
  });

  group('build 2152 — DART-2: the floor-triggered journal line', () {
    test('the shell snapshots the floor and journals on proceed', () {
      final shell = dartSrc('ui/ember/ember_shell.dart');
      // The snapshot reproduces the gate before the call…
      expect(
        shell,
        contains(
          "final floorRefresh =\n"
          "            _bootstrap.donor != 'off' && !_bootstrap.passReady;",
        ),
      );
      // …and a proceed after it journals exactly one line,
      // through the pass-boundary producer.
      expect(shell, contains('if (floorRefresh)'));
      expect(shell, contains('core.journalLine?.call('));
      // The line is one adjacent-string literal in the
      // shell source; pin both halves verbatim.
      expect(
        shell,
        contains("'Mozilla pass refreshed before connecting — '"),
      );
      expect(
        shell,
        contains("'the stored pass was close to expiry.'"),
      );
    });

    test('manual Prepare sites carry no journal line', () {
      final bootstrap = dartSrc('ui/ember/mozilla_bootstrap.dart');
      expect(bootstrap, isNot(contains('journalLine')));
      expect(bootstrap, isNot(contains('close to expiry')));
      final settings = dartSrc('ui/ember/ember_settings.dart');
      expect(settings, isNot(contains('close to expiry')));
    });
  });
}
