/// Build 2095 — owner-reported appearance fix (screenshots
/// Screenshot_2026-11-17-04-46-05-797_com.ralysnd.ember.jpg,
/// the model header panel on blurred glass, and
/// Screenshot_2026-11-17-04-46-01-557_com.ralysnd.ember.jpg,
/// the config rows rendering almost directly on the dotted
/// map, hard to read).
///
/// The fix is ONE container-level backdrop blur per list
/// (MapListFrost, sigma 10 — the header panel's own blur)
/// behind the V2Ray config list, the WireGuard profile
/// list and the OpenVPN profile list. Per-row live
/// BackdropFilters stay banned (builds 2074/2092 jank
/// rule); the rows keep their own fills, borders and the
/// ACTIVE row's orange treatment on top of the frost.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';
import 'package:firefox_vpn/ui/ember/wireguard_pages.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _dart(String path) => File('lib/$path').readAsStringSync();

Profile _vless(String id, String address) => Profile(
  id: id,
  protocol: Protocol.vless,
  name: id,
  address: address,
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  security: 'tls',
  sni: address,
);

Profile _wg(String id, String name) => Profile(
  id: id,
  protocol: Protocol.wireguard,
  name: name,
  address: '10.0.0.1',
  port: 51820,
  uuidOrPassword: '',
  security: '',
  sni: '',
);

void main() {
  group('MapListFrost structure (source)', () {
    test('one shared frost widget with the panel blur, in map_widgets', () {
      final dart = _dart('ui/ember/map_widgets.dart');
      expect(dart, contains('class MapListFrost extends StatelessWidget'));
      expect(dart, contains('BackdropFilter('));
      // MapGlass's own blur + MapListFrost's: exactly the two
      // sanctioned sigma-10 backdrop filters in the file.
      expect(
        'ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10)'.allMatches(dart).length,
        2,
      );
    });

    test('the three config/profile lists are wrapped, Mozilla is not', () {
      final servers = _dart('ui/ember/ember_servers.dart');
      expect(servers, contains('MapListFrost('));
      // The wrap sits on the v2ray branch of the dispatch.
      final dispatch = servers.indexOf('Widget build(BuildContext context)');
      final frost = servers.indexOf('MapListFrost(', dispatch);
      final mozilla = servers.indexOf('_MozillaServers(', dispatch);
      expect(frost, greaterThan(dispatch));
      expect(frost, lessThan(mozilla));
      expect(
        _dart('ui/ember/wireguard_pages.dart'),
        contains('return MapListFrost('),
      );
      expect(
        _dart('ui/ember/openvpn_pages.dart'),
        contains('return MapListFrost('),
      );
    });

    test('no per-row backdrop blur crept into the row widgets', () {
      // The rows themselves must stay filter-free: the frost
      // is container-level only.
      final servers = _dart('ui/ember/ember_servers.dart');
      final subRow = servers.substring(servers.indexOf('class _SubRow'));
      expect(subRow.substring(0, subRow.indexOf('class _GroupHeader')), 
          isNot(contains('BackdropFilter')));
    });
  });

  group('MapListFrost (widget)', () {
    testWidgets('renders exactly one BackdropFilter behind its child', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MapListFrost(child: Center(child: Text('row name'))),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('row name'), findsOneWidget);
      final filter = tester.widget<BackdropFilter>(
        find.byType(BackdropFilter),
      );
      expect(
        filter.filter,
        ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      );
    });
  });

  group('frosted lists (widget)', () {
    testWidgets(
      
      'V2Ray configs: frost present, rows render, selected row keeps '
      'its orange treatment on top',
      (tester) async {
        // PIN UPDATED by build 2137 (visual review #9):
        // the fallback group is a list card now and stands
        // above the Manual card — at the default 800x600
        // surface the second row falls outside the lazy
        // list's build range. The owner's phone surface
        // (411x915) is the honest frame for this page.
        tester.view.physicalSize = const Size(411 * 2, 915 * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final xray = XrayController();
        addTearDown(xray.dispose);
        xray.profiles = [
          _vless('cfg-00', 's0.example.com'),
          _vless('cfg-01', 's1.example.com'),
        ];
        xray.selectedProfileId = 'cfg-00';
        final core = CoreController(
          () async => throw const CoreUnavailable(CoreProblem.refused, 'test'),
        );
        addTearDown(core.dispose);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: EmberServers(
                core: core,
                xray: xray,
                v2ray: true,
                onOpenAccounts: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        // The backing is present behind the list…
        expect(find.byType(MapListFrost), findsOneWidget);
        expect(find.byType(BackdropFilter), findsWidgets);
        // …the rows render on top of it…
        expect(find.text('cfg-00'), findsOneWidget);
        expect(find.text('cfg-01'), findsOneWidget);
        // …and the selected row is still distinguishable:
        // its card carries the selected orange border over
        // the frost. PIN UPDATED by build 2098 (post-2097
        // audit M15): the ACTIVE badge no longer renders
        // for a merely-selected profile — it belongs to
        // the running session's profile only, and nothing
        // is running here.
        expect(find.text('ACTIVE'), findsNothing);
        // PIN UPDATED by batch 2 (fidelity rollout): the
        // selected row's orange treatment changed form — the
        // rim box (the 2119 alpha-0.8 border this pin used to
        // hunt) is retired with every row fill; selection now
        // reads as the flat hairline row plus the 2 px orange
        // tick at its left edge (the pro6-servers treatment).
        // The tick is a plain 2-wide orange Container sibling
        // of the row inside its Stack, so the hunt runs over
        // the whole tree.
        final boxes = tester.widgetList<Container>(find.byType(Container));
        final hasTick = boxes.any(
          (c) =>
              c.color == Ember.orange &&
              c.constraints?.minWidth == 2 &&
              c.constraints?.maxWidth == 2,
        );
        expect(hasTick, isTrue);
      },
    );

    testWidgets('WireGuard profiles: frost present, rows render', (
      tester,
    ) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      xray.profiles = [_wg('wg-00', 'wg-office')];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: WireGuardServersView(xray: xray)),
        ),
      );
      await tester.pump();
      expect(find.byType(MapListFrost), findsOneWidget);
      expect(find.byType(BackdropFilter), findsWidgets);
      expect(find.text('wg-office'), findsOneWidget);
    });
  });
}
