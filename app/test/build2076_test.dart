// Build 2076 — feature queue #6: keep only the fastest N.
// After a Test All, prune a group — or the servers list's
// visible configs — to its fastest N by stored delay, with a
// Map Control confirmation sheet (counts first, Confirm/Cancel,
// Test All offered when there is nothing to rank). The plan is
// pure (testable without a controller); the sheet is a widget
// pumped directly with fake plans.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/fastest_prune_sheet.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String src(String rel) => File('lib/$rel').readAsStringSync();

/// The body of one method, from its signature to the next
/// method — so a "no bare dialog here" pin cannot be fooled
/// by another method in the same file using one.
String fnSegment(String fileSrc, String signature) {
  final start = fileSrc.indexOf(signature);
  expect(start, isNot(-1), reason: '$signature exists');
  final rest = fileSrc.substring(start);
  final next = rest.indexOf('\n  Future<void> ', 10);
  return next == -1 ? rest : rest.substring(0, next);
}

Profile mk(
  String id,
  int delay, {
  String name = '',
  bool failed = false,
  String country = '',
  String sub = '',
}) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: name.isEmpty ? id : name,
  address: 's.example.com',
  delayMs: delay,
  delayFailed: failed,
  exitCountryCode: country,
  subscriptionId: sub,
);

List<Profile> rankedScope() => [
  mk('p50', 50),
  mk('p100', 100),
  mk('p200', 200),
  mk('p300', 300),
  mk('p400', 400),
  mk('p500', 500),
  mk('p600', 600),
  mk('p700', 700),
];

void main() {
  group('planFastestPrune ranking', () {
    test('keeps the N fastest by stored delay, ascending', () {
      final plan = planFastestPrune(rankedScope(), 3);
      expect(plan.state, FastestPruneState.ready);
      expect(
        plan.keep.map((p) => p.id).toList(),
        ['p50', 'p100', 'p200'],
      );
      expect(
        plan.remove.map((p) => p.id).toSet(),
        {'p300', 'p400', 'p500', 'p600', 'p700'},
      );
      expect(plan.testedCount, 8);
      expect(plan.scopeTotal, 8);
    });

    test('N boundaries 3 / 5 / 10', () {
      expect(planFastestPrune(rankedScope(), 3).keep.length, 3);
      expect(planFastestPrune(rankedScope(), 5).keep.length, 5);
      // Only 8 measured: N=10 cannot rank, so nothing to prune.
      expect(
        planFastestPrune(rankedScope(), 10).state,
        FastestPruneState.nothingToPrune,
      );
      final twelve = [
        ...rankedScope(),
        mk('p800', 800),
        mk('p900', 900),
        mk('p1000', 1000),
        mk('p1100', 1100),
      ];
      expect(planFastestPrune(twelve, 10).keep.length, 10);
      expect(planFastestPrune(twelve, 10).remove.length, 2);
    });

    test('untested profiles sort last and are removed once ranked', () {
      final scope = [
        mk('fast', 100),
        mk('slow', 300),
        mk('mid', 200),
        mk('never', -1),
        mk('failed', -1, failed: true),
        mk('fourth', 400),
      ];
      final plan = planFastestPrune(scope, 3);
      expect(plan.state, FastestPruneState.ready);
      expect(
        plan.keep.map((p) => p.id).toList(),
        ['fast', 'mid', 'slow'],
      );
      expect(
        plan.remove.map((p) => p.id).toSet(),
        {'fourth', 'never', 'failed'},
      );
      // Both removed untested profiles count — failed or never.
      expect(plan.untestedRemoved, 2);
    });

    test('a failed test counts as untested, not as slow', () {
      final scope = [
        mk('a', 100),
        mk('b', 200),
        mk('c', 300),
        mk('d', 400),
        mk('failed', -1, failed: true),
      ];
      final plan = planFastestPrune(scope, 3);
      expect(plan.remove.map((p) => p.id), contains('failed'));
      expect(plan.untestedRemoved, 1);
    });

    test('the active profile is never deleted, even outside N', () {
      final scope = rankedScope();
      final bySelected = planFastestPrune(
        scope,
        3,
        selectedId: 'p700',
      );
      expect(bySelected.keep.map((p) => p.id), contains('p700'));
      expect(bySelected.remove.map((p) => p.id), isNot(contains('p700')));
      expect(bySelected.activeKeptOutsideN?.id, 'p700');
      // It counts outside N: 3 fastest + the active one.
      expect(bySelected.keep.length, 4);

      final byConnected = planFastestPrune(
        scope,
        3,
        activeId: 'p600',
      );
      expect(byConnected.activeKeptOutsideN?.id, 'p600');
      expect(byConnected.remove.map((p) => p.id), isNot(contains('p600')));
    });

    test('an active profile inside the fastest N needs no note', () {
      final plan = planFastestPrune(rankedScope(), 3, selectedId: 'p100');
      expect(plan.activeKeptOutsideN, isNull);
      expect(plan.keep.length, 3);
    });

    test('an untested active profile is kept, not pruned blind', () {
      final scope = [...rankedScope(), mk('active-new', -1)];
      final plan = planFastestPrune(scope, 3, selectedId: 'active-new');
      expect(plan.keep.map((p) => p.id), contains('active-new'));
      expect(plan.activeKeptOutsideN?.id, 'active-new');
      expect(plan.remove.map((p) => p.id), isNot(contains('active-new')));
    });

    test('a country-excluded profile is never among the kept', () {
      final scope = [
        mk('fast-excluded', 10, country: 'IR'),
        mk('a', 100),
        mk('b', 200),
        mk('c', 300),
        mk('d', 400),
      ];
      final plan = planFastestPrune(
        scope,
        3,
        excludedCountries: {'IR'},
      );
      expect(plan.keep.map((p) => p.id).toList(), ['a', 'b', 'c']);
      expect(plan.remove.map((p) => p.id), contains('fast-excluded'));
      expect(plan.eligibleCount, 4);
      expect(plan.testedCount, 5);
    });

    test('exclusion can leave nothing to prune', () {
      final scope = [
        mk('a', 100, country: 'IR'),
        mk('b', 200, country: 'IR'),
        mk('c', 300),
        mk('d', 400),
      ];
      final plan = planFastestPrune(
        scope,
        3,
        excludedCountries: {'IR'},
      );
      expect(plan.state, FastestPruneState.nothingToPrune);
      expect(plan.remove, isEmpty);
    });
  });

  group('planFastestPrune edge states', () {
    test('empty scope has no results', () {
      final plan = planFastestPrune(const [], 5);
      expect(plan.state, FastestPruneState.noResults);
      expect(plan.testedCount, 0);
      expect(plan.remove, isEmpty);
    });

    test('all-untested scope has no results — never prune blind', () {
      final scope = [mk('a', -1), mk('b', -1), mk('c', -1)];
      final plan = planFastestPrune(scope, 3);
      expect(plan.state, FastestPruneState.noResults);
      expect(plan.remove, isEmpty);
    });

    test('tested count at or below N is nothing to prune', () {
      final threeOfEight = [
        mk('a', 100),
        mk('b', 200),
        mk('c', 300),
        mk('d', -1),
        mk('e', -1),
        mk('f', -1),
        mk('g', -1),
        mk('h', -1),
      ];
      final atN = planFastestPrune(threeOfEight, 3);
      expect(atN.state, FastestPruneState.nothingToPrune);
      expect(atN.remove, isEmpty);
      final belowN = planFastestPrune(threeOfEight, 5);
      expect(belowN.state, FastestPruneState.nothingToPrune);
      // One more measurement makes it prunable.
      final fourTested = [
        ...threeOfEight.sublist(0, 3),
        mk('d', 400),
        ...threeOfEight.sublist(4),
      ];
      final ready = planFastestPrune(fourTested, 3);
      expect(ready.state, FastestPruneState.ready);
      expect(ready.remove.length, 5);
    });
  });

  group('controller apply', () {
    test('apply deletes only the planned profiles, in memory', () async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      xray.profiles = rankedScope();
      xray.selectedProfileId = 'p700';
      final plan = xray.planFastestPruneFor(xray.profiles, 3);
      expect(plan.keep.map((p) => p.id).toSet(), {
        'p50',
        'p100',
        'p200',
        'p700',
      });
      final removed = await xray.applyFastestPrune(plan);
      expect(removed, 4);
      expect(
        xray.profiles.map((p) => p.id).toSet(),
        {'p50', 'p100', 'p200', 'p700'},
      );
    });

    test('a non-ready plan removes nothing', () async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      xray.profiles = [mk('a', 100), mk('b', 200), mk('c', -1)];
      final plan = xray.planFastestPruneFor(xray.profiles, 5);
      expect(plan.state, FastestPruneState.nothingToPrune);
      expect(await xray.applyFastestPrune(plan), 0);
      expect(xray.profiles.length, 3);
    });

    test('store round-trip: only the pruned profiles are gone', () async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      xray.profiles = rankedScope();
      final plan = xray.planFastestPruneFor(xray.profiles, 5);
      await xray.applyFastestPrune(plan);
      // The whole store document, as the app persists it:
      // encode what remains, decode it back, and the kept set
      // — and only the kept set — survives.
      final encoded = jsonEncode(
        xray.profiles.map((p) => p.toJson()).toList(),
      );
      final back = (jsonDecode(encoded) as List)
          .map((j) => Profile.fromJson(j as Map<String, dynamic>))
          .toList();
      expect(back.map((p) => p.id).toSet(), {
        'p50',
        'p100',
        'p200',
        'p300',
        'p400',
      });
      expect(back.map((p) => p.delayMs).toSet(), {50, 100, 200, 300, 400});
    });

    test('the subscription wrappers still prune one subscription', () async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final sub = Subscription(id: 's1', name: 'Sub One');
      xray.subscriptions = [sub];
      xray.profiles = [
        ...rankedScope().map((p) => p..subscriptionId = 's1'),
        mk('loose', 10),
      ];
      final victims = xray.fastestPruneVictims(sub, 3);
      expect(victims.map((p) => p.id).toSet(), {
        'p300',
        'p400',
        'p500',
        'p600',
        'p700',
      });
      final removed = await xray.keepFastestInSubscription(sub, 3);
      expect(removed, 5);
      expect(
        xray.profilesOf(sub).map((p) => p.id).toSet(),
        {'p50', 'p100', 'p200'},
      );
      // The loose config was never in the subscription's scope.
      expect(xray.profiles.map((p) => p.id), contains('loose'));
    });
  });

  group('FastestPruneSheet widget', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required FastestPrunePlan Function(int n) planFor,
      required Future<int> Function(FastestPrunePlan plan) onConfirm,
      Future<void> Function()? onRunTestAll,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FastestPruneSheet(
              scopeName: 'Test scope',
              planFor: planFor,
              onConfirm: onConfirm,
              onRunTestAll: onRunTestAll,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('ready state shows counts, Confirm prunes', (tester) async {
      FastestPrunePlan? confirmed;
      await pumpSheet(
        tester,
        planFor: (n) => planFastestPrune(rankedScope(), n),
        onConfirm: (plan) async {
          confirmed = plan;
          return plan.remove.length;
        },
      );
      expect(find.text('Keep only the fastest'), findsOneWidget);
      expect(find.text('3 configs'), findsOneWidget);
      expect(find.text('5 configs'), findsOneWidget);
      expect(find.text('Remove 3'), findsOneWidget);
      expect(find.textContaining('p50'), findsWidgets);
      await tester.tap(find.text('Remove 3'));
      await tester.pump();
      expect(confirmed, isNotNull);
      expect(confirmed!.remove.length, 3);
    });

    testWidgets('the N picker recomputes the plan', (tester) async {
      await pumpSheet(
        tester,
        planFor: (n) => planFastestPrune(rankedScope(), n),
        onConfirm: (plan) async => plan.remove.length,
      );
      expect(find.text('Remove 3'), findsOneWidget);
      await tester.tap(find.text('3'));
      await tester.pump();
      expect(find.text('Remove 5'), findsOneWidget);
      expect(find.text('Remove 3'), findsNothing);
    });

    testWidgets('Cancel prunes nothing', (tester) async {
      var confirmed = false;
      await pumpSheet(
        tester,
        planFor: (n) => planFastestPrune(rankedScope(), n),
        onConfirm: (plan) async {
          confirmed = true;
          return 0;
        },
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(confirmed, isFalse);
    });

    testWidgets('active-kept-outside-N is named in the sheet', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        planFor: (n) =>
            planFastestPrune(rankedScope(), n, selectedId: 'p700'),
        onConfirm: (plan) async => plan.remove.length,
      );
      expect(find.textContaining('is the active config'), findsOneWidget);
      expect(find.textContaining('p700'), findsWidgets);
    });

    testWidgets('no results offers Test All, never a blind prune', (
      tester,
    ) async {
      var tested = false;
      await pumpSheet(
        tester,
        planFor: (n) => planFastestPrune([
          mk('a', -1),
          mk('b', -1),
        ], n),
        onConfirm: (plan) async => plan.remove.length,
        onRunTestAll: () async {
          tested = true;
        },
      );
      expect(find.text('Run Test All'), findsOneWidget);
      expect(find.textContaining('Remove'), findsNothing);
      await tester.tap(find.text('Run Test All'));
      await tester.pump();
      expect(tested, isTrue);
    });

    testWidgets('nothing to prune states the reason, no Remove', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        planFor: (n) => planFastestPrune([
          mk('a', 100),
          mk('b', 200),
          mk('c', -1),
        ], n),
        onConfirm: (plan) async => plan.remove.length,
        onRunTestAll: () async {},
      );
      expect(find.textContaining('Only 2 of 3 configs'), findsOneWidget);
      expect(find.textContaining('Remove'), findsNothing);
      expect(find.text('Run Test All'), findsOneWidget);
    });
  });

  group('wiring pins', () {
    test('the servers Sort menu carries Keep fastest N', () {
      final servers = src('ui/ember/ember_servers.dart');
      expect(servers, contains("value: 'keepFastest'"));
      expect(servers, contains("child: Text('Keep fastest N…')"));
      expect(servers, contains("import 'fastest_prune_sheet.dart';"));
      expect(servers, contains('showFastestPruneSheet('));
    });

    test('the group-header prune uses the sheet, not a dialog', () {
      final segment = fnSegment(
        src('ui/ember/ember_servers.dart'),
        'Future<void> _pruneSub',
      );
      expect(segment, contains('showFastestPruneSheet('));
      expect(segment, isNot(contains('AlertDialog')));
      expect(segment, contains('profilesOf(sub)'));
    });

    test('the accounts keep-fastest flow uses the sheet', () {
      final segment = fnSegment(
        src('ui/ember/ember_accounts.dart'),
        'Future<void> _keepFastestFlow',
      );
      expect(segment, contains('showFastestPruneSheet('));
      expect(segment, isNot(contains('AlertDialog')));
    });

    test('the controller exposes the plan + apply pair', () {
      final controller = src('xray/xray_controller.dart');
      expect(controller, contains('FastestPrunePlan planFastestPrune('));
      expect(controller, contains('planFastestPruneFor('));
      expect(controller, contains('applyFastestPrune('));
    });
  });
}
