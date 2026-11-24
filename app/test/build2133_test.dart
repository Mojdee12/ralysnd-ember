// Build 2133 — the V2Ray full tab with per-subscription
// ping (owner order 2026-11-22, design sample v5).
//
// V2Ray used to be a panel inside the shell's Servers
// tab, under the map and the engine rail, with a Test
// All button that delay-tested every visible config.
// The owner ordered a dedicated full-screen V2Ray page
// where each subscription card pings ONLY itself:
//
// - V2RayPage is its own Scaffold route; the shell's two
//   V2Ray entry points (Locations pill, V2Ray home card)
//   push it when mode == 1.
// - The tab's groups are cards: one per subscription
//   (name, count, updated-ago, traffic/days-left only
//   when the stored metadata carries them), the Manual
//   configs card last; Favorites and smart groups stay
//   flat sections; the By-country view is untouched.
// - A card's Ping runs the existing delay funnel over
//   ONLY that group's shown profiles and, on completion,
//   persists a Best/Last-ping summary (Subscription
//   fields; settings fields for the loose group).
// - There is no Test All button anywhere on the tab.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String rel) => File(rel).readAsStringSync();

void main() {
  final servers = read('lib/ui/ember/ember_servers.dart');
  final shell = read('lib/ui/ember/ember_shell.dart');
  final models = read('lib/xray/xray_models.dart');
  final en = read('lib/l10n/app_en.arb');
  final fa = read('lib/l10n/app_fa.arb');
  final pubspec = read('pubspec.yaml');

  group('the full-screen page', () {
    test('V2RayPage is its own Scaffold over the map backdrop', () {
      final at = servers.indexOf('class V2RayPage extends StatelessWidget');
      expect(at, greaterThanOrEqualTo(0));
      final body = servers.substring(at, at + 1600);
      expect(body, contains('Scaffold('));
      // PIN UPDATED by the build 2145 fix round (A3): the
      // page's backdrop is the banded treatment — map as a
      // top band, body rows on plain near-black.
      expect(body, contains('MapBackdropVisual(banded: true)'));
      // PIN UPDATED by the fidelity rollout batch 3
      // (pro6-v2ray): the page drops its MapListFrost — the
      // sample's header band is a readable dotted globe with
      // its filament arc, the frost blurred it back into the
      // old glass language (and a live BackdropFilter in a
      // scroll view is the V-23 jank class). The banded scrim
      // carries legibility; the Servers TAB keeps its frost.
      expect(body.contains('MapListFrost('), isFalse);
      expect(body, contains('pageLead: true'));
      // Its close button pops the route.
      expect(body, contains('Navigator.of(context).maybePop()'));
    });

    test('the shell pushes the page for V2Ray from _openServersTab', () {
      final at = shell.indexOf('void _openServersTab()');
      expect(at, greaterThanOrEqualTo(0));
      final body = shell.substring(at, at + 700);
      expect(body, contains('if (mode == 1)'));
      expect(body, contains('MaterialPageRoute('));
      expect(body, contains('V2RayPage('));
      // Other engines keep the Servers tab.
      expect(body, contains('setState(() => _tab = 1);'));
    });

    test('both V2Ray entry points route through _openServersTab', () {
      // PIN UPDATED by build 2147 (fix item #23): the
      // 'onTap: _openServersTab,' instance this pin counted
      // was the old header tower's Locations pill — dead code
      // (it sat behind an if (_tab == 0) guard inside the
      // non-Home branch, so it never rendered) — and the
      // tower is deleted by #23. The LIVE entry points stand:
      // the slim control bar's Locations route
      // (onOpenServers:) and the control bar's servers action
      // (onServers:), both still wired to _openServersTab.
      expect(shell, contains('onOpenServers: _openServersTab,'));
      expect(shell, contains('onServers: _openServersTab,'));
    });

    test('the page header is the sample anatomy', () {
      // PIN UPDATED by build 2144 (reskin): the glass
      // MapPanelHeader (title: 'V2Ray') became open
      // typography — the same 'V2Ray' string in Ember.hero,
      // QR Scan / Add as bare orange text actions in the
      // header row (same labels, same callbacks).
      expect(servers, contains("'V2Ray',"));
      expect(servers, contains('style: Ember.hero'));
      expect(servers.contains("'V2Ray CONFIGURATIONS'"), isFalse);
      // Connected strip + summary caption + buttons row.
      // PIN UPDATED by the build 2145 fix round (A10 widget
      // composition): the _statusStrip method became the
      // _StatusStrip widget class in the same header slot.
      expect(servers, contains('_StatusStrip(xray: xray)'));
      expect(servers, contains('l.tabSummary('));
      expect(servers, contains("label: 'Import'"));
      expect(servers, contains("label: 'QR Scan'"));
      expect(servers, contains("Text('Add', style: _headerActionStyle)"));
      expect(servers, contains('showAddSubscriptionSheet(context, xray)'));
    });

    test('the status strip reads the session profile like the shell bar', () {
      // PIN UPDATED by the build 2145 fix round (A10):
      // anchor on the _StatusStrip widget class; its build
      // still reads the session profile exactly as pinned.
      final at = servers.indexOf('class _StatusStrip extends StatelessWidget');
      expect(at, greaterThanOrEqualTo(0));
      final body = servers.substring(at, at + 1200);
      expect(body, contains('xray.sessionProfile ?? xray.selected'));
      expect(body, contains('xray.state.running && !xray.warpSession'));
    });
  });

  group('per-subscription ping', () {
    final pingAt = servers.indexOf('Future<void> _pingGroup({');
    final pingBody = servers.substring(pingAt, pingAt + 1500);

    test('the scoped ping runs the funnel over only the group members', () {
      expect(pingAt, greaterThanOrEqualTo(0));
      expect(
        pingBody,
        contains('final cancelled = await xray.testAllDelays(only: members);'),
      );
      // A second tap on the running card stops the funnel.
      expect(
        pingBody,
        contains('if (_pingGroupKey == key) xray.stopTestAll();'),
      );
      // A cancelled run records nothing; a completed one saves.
      expect(pingBody, contains('if (!cancelled)'));
      expect(pingBody, contains('await xray.save();'));
      // No store-wide sort follows a group ping.
      expect(pingBody.contains('sortProfilesByDelay'), isFalse);
    });

    test(
      'the subscription card pings its own members and records on the sub',
      () {
        final base = servers.indexOf('List<_ServersItem> _defaultItems(');
        final at = servers.indexOf(
          'for (final sub in xray.subscriptions)',
          base,
        );
        expect(at, greaterThanOrEqualTo(0));
        // Window widened by build 2144 (reskin): the
        // block grew by the subscription traffic hero;
        // every pin below is unchanged.
        // Widened again by build 2147: the card head grew
        // the balancer opt-in (feature #5) and the F4
        // warning-state fields.
        final body = servers.substring(at, at + 4300);
        expect(body, contains('_ServersCardHeadItem('));
        expect(body, contains('_subCardSubtitle(sub, members.length)'));
        expect(body, contains('members: members,'));
        expect(body, contains('sub.lastPingMs ='));
        expect(body, contains('sub.bestPingName = name;'));
        expect(body, contains('sub.bestPingMs = ms;'));
        // The card keeps the old group's refresh + prune.
        expect(
          body,
          contains('onRefresh: () => unawaited(_refreshSub(sub.id))'),
        );
        expect(
          body,
          contains('onPrune: () => unawaited(_pruneSub(sub.id, sub.name))'),
        );
        // Expanded rows are lazy sliver slices, not an eager
        // column (build 2055's A-H4 guarantee survives).
        expect(
          body,
          contains('_ServersCardProfileItem(members[i], first: i == 0)'),
        );
        expect(body, contains('_ServersCardFootItem()'));
      },
    );

    test(
      'the Manual configs card pings the loose profiles, summary on settings',
      () {
        final base = servers.indexOf('List<_ServersItem> _defaultItems(');
        final at = servers.indexOf('if (loose.isNotEmpty) {', base);
        expect(at, greaterThanOrEqualTo(0));
        final body = servers.substring(at, at + 2200);
        expect(body, contains('members: loose,'));
        expect(body, contains('settings.looseLastPingMs ='));
        expect(body, contains('settings.looseBestPingName = name;'));
        expect(body, contains('settings.looseBestPingMs = ms;'));
        expect(body, contains('title: l.manualConfigsGroup,'));
      },
    );

    test('the Manual configs card renders after the subscription cards', () {
      final at = servers.indexOf('List<_ServersItem> _defaultItems(');
      expect(at, greaterThanOrEqualTo(0));
      final body = servers.substring(at, at + 6500);
      expect(
        body.indexOf('for (final sub in xray.subscriptions)'),
        lessThan(body.indexOf('title: l.manualConfigsGroup,')),
      );
      expect(body, contains('title: l.subscriptionsTitle,'));
    });

    test('there is no Test All affordance on the tab', () {
      // The old action-bar cell and its classes are gone.
      expect(servers.contains('_ActionCell('), isFalse);
      expect(
        servers.contains("label: xray.scanRunning ? 'Stop' : 'Test All'"),
        isFalse,
      );
      expect(servers.contains('Future<void> _testAll()'), isFalse);
      // The global keep-fastest sheet gets no test run from this tab.
      final at = servers.indexOf('Future<void> _keepFastestFlow()');
      final body = servers.substring(at, at + 1600);
      expect(body, contains('onRunTestAll: null,'));
    });
  });

  group('card summary rendering', () {
    test('the summary line renders Best / Last ping / Not tested yet', () {
      // PIN UPDATED by the build 2145 fix round (A10):
      // anchor on the _PingSummaryLine widget class; the
      // ago formatter is now its agoText field — the three
      // rendered strings are unchanged.
      final at = servers.indexOf('class _PingSummaryLine extends StatelessWidget');
      expect(at, greaterThanOrEqualTo(0));
      final body = servers.substring(at, at + 1100);
      expect(body, contains('l.notTestedYet'));
      expect(body, contains('l.bestPingResult(bestName, bestMs)'));
      expect(body, contains('l.lastPingLabel(agoText(lastPingMs))'));
    });

    test(
      'traffic and days-left render only when the metadata carries them',
      () {
        final at = servers.indexOf('String _subCardSubtitle(');
        expect(at, greaterThanOrEqualTo(0));
        final body = servers.substring(at, at + 1100);
        expect(body, contains('if (sub.totalBytes > 0)'));
        expect(body, contains('if (sub.expireEpochSec > 0)'));
        expect(body, contains('sub.remainingDays > 0'));
      },
    );

    test('the summary persists on the models', () {
      expect(models, contains("'lastPingMs': lastPingMs,"));
      expect(models, contains("'bestPingName': bestPingName,"));
      expect(models, contains("bestPingMs: _storedInt(j, 'bestPingMs', -1),"));
      expect(models, contains("'looseLastPingMs': looseLastPingMs,"));
      expect(models, contains("'looseBestPingName': looseBestPingName,"));
      expect(models, contains("s.looseBestPingMs = _storedInt("));
    });

    test('the new strings exist in en and fa', () {
      expect(en, contains('"manualConfigsGroup": "Manual configs"'));
      expect(en, contains('"notTestedYet": "Not tested yet"'));
      expect(en, contains('"bestPingResult": "Best: {name} · {ms} ms"'));
      expect(fa, contains('"manualConfigsGroup": "کانفیگ‌های دستی"'));
      expect(fa, contains('"notTestedYet": "هنوز تست نشده"'));
      expect(fa, contains('"tabSummary": "{subs} اشتراک · {servers} سرور"'));
    });
  });

  test('pubspec is build 2133', () {
    expect(pubspec, contains('version: 2.2.0+2147'));
  });
}
