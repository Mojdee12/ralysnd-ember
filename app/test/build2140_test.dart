// Build 2140 — two legs (scope: build2140-progress.md):
//
//  LEG A — the FLAG_SECURE leak: the shell keeps every
//  tab page mounted in an IndexedStack, and the accounts
//  page's root OverlayGuard counted from mount to a
//  dispose that never comes, so screenshots were blocked
//  app-wide, permanently. OverlayGuard now holds its
//  share of the count only while its surface is VISIBLE
//  (the surrounding TickerMode — the shell's own
//  tab-selection signal since build 2050). Pushed routes
//  and the lock page have no disabled TickerMode above
//  them and keep the mount-lifetime behaviour.
//
//  LEG B — RegionHop observability + honest empty
//  state: the page journals its panel flow (outcomes,
//  row counts, error kinds — never the URL, password,
//  cookie or relay credentials), and the Locations
//  empty area distinguishes loading / load-failed /
//  truly-empty instead of calling every failure an
//  empty panel.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/regionhop/regionhop_client.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';
import 'package:firefox_vpn/ui/ember/regionhop_page.dart';

String _src(String rel) => File('lib/$rel').readAsStringSync();

/// Records the two window-guard platform calls the
/// OverlayGuard drives (channel 'app/android', the
/// build2054 mock precedent).
class _GuardChannel {
  final List<String> calls = [];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), (
          call,
        ) async {
          if (call.method == 'setSecureFlag' ||
              call.method == 'setOverlayGuard') {
            final args = call.arguments as Map;
            calls.add('${call.method}:${args['on']}');
          }
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
  }

  int count(String method, bool on) =>
      calls.where((c) => c == '$method:$on').length;

  void expectHeld() {
    expect(count('setSecureFlag', true), 1, reason: calls.join(','));
    expect(count('setOverlayGuard', true), 1, reason: calls.join(','));
    expect(count('setSecureFlag', false), 0, reason: calls.join(','));
    expect(OverlayGuard.depth, 1);
  }

  void expectReleased() {
    expect(count('setSecureFlag', false), 1, reason: calls.join(','));
    expect(count('setOverlayGuard', false), 1, reason: calls.join(','));
    expect(OverlayGuard.depth, 0);
  }

  void expectNeverHeld() {
    expect(calls, isEmpty, reason: calls.join(','));
    expect(OverlayGuard.depth, 0);
  }
}

void main() {
  group('LEG A — OverlayGuard tracks visible surfaces only', () {
    late _GuardChannel channel;

    setUp(() {
      channel = _GuardChannel()..install();
    });

    tearDown(() {
      channel.uninstall();
    });

    testWidgets('no TickerMode ancestor: held while mounted, '
        'released on unmount (pushed-route behaviour)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: OverlayGuard(child: SizedBox())),
      );
      await tester.pump();
      channel.expectHeld();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      channel.expectReleased();
    });

    testWidgets('a disabled TickerMode holds nothing; flipping '
        'it takes and releases the flag', (tester) async {
      Widget tree(bool enabled) => MaterialApp(
        home: TickerMode(
          enabled: enabled,
          child: const OverlayGuard(child: SizedBox()),
        ),
      );
      await tester.pumpWidget(tree(false));
      await tester.pump();
      channel.expectNeverHeld();
      await tester.pumpWidget(tree(true));
      await tester.pump();
      channel.expectHeld();
      await tester.pumpWidget(tree(false));
      await tester.pump();
      channel.expectReleased();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('IndexedStack geometry (the shell): a guarded '
        'tab page holds the flag only while its tab is selected', (
      tester,
    ) async {
      // The shell's gatedPages shape: every page wrapped
      // in TickerMode(enabled: _tab == i), all mounted in
      // an IndexedStack.
      Widget stack(int tab) => MaterialApp(
        home: IndexedStack(
          index: tab,
          children: [
            TickerMode(enabled: tab == 0, child: const SizedBox()),
            TickerMode(
              enabled: tab == 1,
              child: const OverlayGuard(child: SizedBox()),
            ),
          ],
        ),
      );
      await tester.pumpWidget(stack(0));
      await tester.pump();
      channel.expectNeverHeld();
      await tester.pumpWidget(stack(1));
      await tester.pump();
      channel.expectHeld();
      await tester.pumpWidget(stack(0));
      await tester.pump();
      channel.expectReleased();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nested visible guards hold the window once; '
        'the flag lifts only when the last one goes', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: OverlayGuard(child: OverlayGuard(child: SizedBox())),
        ),
      );
      await tester.pump();
      expect(OverlayGuard.depth, 2);
      expect(channel.count('setSecureFlag', true), 1);
      // The inner guard goes away; the outer still holds.
      await tester.pumpWidget(
        const MaterialApp(home: OverlayGuard(child: SizedBox())),
      );
      await tester.pump();
      expect(OverlayGuard.depth, 1);
      expect(channel.count('setSecureFlag', false), 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      channel.expectReleased();
    });

    testWidgets('the lock page holds the flag while shown and '
        'releases it after unlock', (tester) async {
      final settings = AppSettings()
        ..update(appLockPinHash: pinHashOf('1234'));
      var unlocked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(
            settings: settings,
            onUnlocked: () => unlocked = true,
          ),
        ),
      );
      await tester.pump();
      channel.expectHeld();
      for (final digit in ['1', '2', '3', '4']) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      expect(unlocked, isTrue);
      // The shell swaps the lock page out on unlock; the
      // guard's share goes with it.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      channel.expectReleased();
    });

    test('the accounts page keeps its guard — now visibility-fed', () {
      final accounts = _src('ui/ember/ember_accounts.dart');
      expect(accounts, contains('OverlayGuard('));
      final guard = _src('ui/ember/map_widgets.dart');
      expect(guard, contains('TickerMode.valuesOf(context).enabled'));
      expect(guard, contains('didChangeDependencies'));
    });
  });

  group('LEG B — RegionHop journal', () {
    late List<(String, bool?)> lines;
    late RegionHopJournal journal;

    setUp(() {
      lines = [];
      journal = RegionHopJournal((text, {ok}) => lines.add((text, ok)));
    });

    test('login outcomes journal with their kind', () {
      journal.loginOk();
      journal.loginFailed(RegionHopErrorKind.loginFailed);
      journal.loginFailed(RegionHopErrorKind.lockout);
      expect(lines, [
        ('panel login ok', true),
        ('panel login failed — loginFailed', false),
        ('panel login failed — lockout', false),
      ]);
    });

    test('fetch lines journal row counts and kinds, deduped '
        'across the 5 s poll until the outcome changes', () {
      journal.fetchOk(3);
      journal.fetchOk(3); // the next poll, unchanged: silent
      journal.fetchOk(3);
      journal.fetchOk(2); // a location went away: journals
      journal.fetchFailed(RegionHopErrorKind.badResponse);
      journal.fetchFailed(RegionHopErrorKind.badResponse); // silent
      journal.fetchFailed(RegionHopErrorKind.unreachable); // new kind
      journal.fetchOk(2); // recovery journals even at the old count
      expect(lines, [
        ('status fetch ok — 3 locations', true),
        ('status fetch ok — 2 locations', true),
        ('status fetch failed — badResponse', false),
        ('status fetch failed — unreachable', false),
        ('status fetch ok — 2 locations', true),
      ]);
    });

    test('a fresh login re-arms the fetch line', () {
      journal.fetchOk(3);
      journal.loginOk();
      journal.fetchOk(3);
      expect(lines, [
        ('status fetch ok — 3 locations', true),
        ('panel login ok', true),
        ('status fetch ok — 3 locations', true),
      ]);
    });

    test('probe and start/stop journal outcomes and kinds only', () {
      journal.probeOutcome('de', true);
      journal.probeOutcome('de', false);
      journal.probeFailed('nl', RegionHopErrorKind.unreachable);
      journal.actionOutcome('de', true);
      journal.actionOutcome('de', false);
      journal.actionFailed('us', true, RegionHopErrorKind.badResponse);
      expect(lines, [
        ('probe de passed', true),
        ('probe de did not pass', false),
        ('probe nl failed — unreachable', false),
        ('start de ok', true),
        ('stop de ok', true),
        ('start us failed — badResponse', false),
      ]);
    });

    test('no journal line can carry a secret', () {
      journal.loginOk();
      journal.fetchOk(0);
      journal.fetchFailed(RegionHopErrorKind.notFound);
      journal.probeOutcome('de', true);
      journal.actionOutcome('de', true);
      final all = lines.map((l) => l.$1).join('\n');
      // The writer's vocabulary is outcomes, counts and
      // kinds — there is no slot a URL, path prefix,
      // password, cookie, exit IP or relay credential
      // could travel in.
      expect(all, isNot(contains('http')));
      expect(all, isNot(contains('password')));
      expect(all, isNot(contains('psi_session')));
      expect(all, isNot(contains('rh-')));
      expect(RegExp(r'\d+\.\d+\.\d+\.\d+').hasMatch(all), isFalse);
    });

    test('the page journals through the diagnostics journal '
        'and the client stays untouched', () {
      final page = _src('ui/ember/regionhop_page.dart');
      expect(page, contains("diagnostics.add('regionhop'"));
      expect(page, contains('_journal.loginOk()'));
      expect(page, contains('_journal.loginFailed(e.kind)'));
      expect(page, contains('_journal.fetchOk(locations.length)'));
      expect(page, contains('_journal.fetchFailed(e.kind, e.transport)'));
      expect(page, contains('_journal.probeOutcome'));
      expect(page, contains('_journal.actionOutcome'));
      final client = _src('regionhop/regionhop_client.dart');
      expect(client, isNot(contains('diagnostics')));
      expect(client, isNot(contains('RegionHopJournal')));
    });
  });

  group('LEG B — the honest empty area', () {
    testWidgets('loading claims nothing about the panel', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RegionHopListEmpty(state: RegionHopListState.loading),
          ),
        ),
      );
      expect(find.text('Loading locations…'), findsOneWidget);
      expect(find.textContaining('No locations'), findsNothing);
    });

    testWidgets('a failed load says so, with the error — never '
        'that the panel is empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RegionHopListEmpty(
              state: RegionHopListState.loadFailed,
              error: 'The panel answered in an unexpected way.',
            ),
          ),
        ),
      );
      expect(
        find.text(
          'Could not load the locations — '
          'The panel answered in an unexpected way.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('No locations on this panel'), findsNothing);
      expect(find.textContaining('add them in the web panel'), findsNothing);
    });

    testWidgets('only a successful zero-row fetch earns the '
        'empty-panel wording', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RegionHopListEmpty(state: RegionHopListState.empty),
          ),
        ),
      );
      expect(
        find.text(
          'No locations on this panel yet — add them '
          'in the web panel.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Could not load'), findsNothing);
    });

    test('the page drives the empty area from the fetch outcome', () {
      final page = _src('ui/ember/regionhop_page.dart');
      expect(page, contains('RegionHopListEmpty('));
      expect(page, contains('_listState = RegionHopListState.loadFailed'));
      expect(page, contains('_listState = RegionHopListState.empty'));
      expect(page, contains('_listState = RegionHopListState.loading'));
    });
  });

  group('build pins', () {
    test('pubspec is 2.2.0+2148', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.2.0+2152'),
      );
    });
  });
}
