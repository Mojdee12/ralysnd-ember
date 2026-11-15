/// Build 2056 gates — audit Batch 12 (editors + sign-in
/// surfaces).
///
/// - F-M9: editor dropdowns clamp parser-reachable values
///   outside their option lists in initState, so an imported
///   profile opens instead of throwing (network splithttp/raw/
///   h2, SS method chacha20-poly1305/aes-256-cfb, non-
///   salamander Hy2 obfs, unknown gRPC mode / fragment shape).
///   Safe renames are mapped (splithttp→xhttp, h2→HTTP/2,
///   chacha20-poly1305→chacha20-ietf-poly1305); the rest fall
///   back to the default option.
/// - WARP Renew: tapping Renew persists the form and stays on
///   the settings page, reporting the outcome in an inline
///   line — it no longer pops the page via _save.
/// - Sign-in dialog: fits a 360 px phone (no fixed 400 px
///   width), long email title ellipsised to one line.
/// - Bootstrap relay fields use emberField; no raw Material
///   underline decoration remains in mozilla_bootstrap.dart.
/// - A-H3: no stock OutlinedButton/FilledButton remains in
///   profile_editor.dart or mozilla_bootstrap.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/core/models.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/ui/ember/warp_settings_page.dart';
import 'package:firefox_vpn/ui/signin_dialog.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

String _dart(String path) => File('lib/$path').readAsStringSync();

Profile _vless({
  String network = 'tcp',
  String mode = '',
  String afFragment = '',
}) => Profile(
  id: 't1',
  protocol: Protocol.vless,
  name: 't1',
  address: 'v.example.com',
  port: 443,
  uuidOrPassword: '00000000-0000-4000-8000-000000000000',
  network: network,
  mode: mode,
  afFragment: afFragment,
  security: 'tls',
  sni: 'v.example.com',
);

Future<void> _pumpEditor(
  WidgetTester tester,
  XrayController xray,
  Profile existing,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ProfileEditorPage(xray: xray, existing: existing),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('F-M9 editor dropdowns clamp imported values', () {
    testWidgets('network splithttp opens as the XHTTP chip', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = _vless(network: 'splithttp');
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      // Build 2074: the sections above Transport grew (48 dp
      // targets), so the Transport section now starts below the
      // test viewport's build range — scroll it into view first.
      // The scrollable must be named: the page ListView's own
      // Scrollable (the tree holds 8 — every chip picker has one).
      await tester.scrollUntilVisible(
        find.widgetWithText(EmberChip, 'XHTTP'),
        120,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester
            .widget<EmberChip>(find.widgetWithText(EmberChip, 'XHTTP'))
            .selected,
        isTrue,
      );
    });

    testWidgets('network raw opens as the TCP chip', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = _vless(network: 'raw');
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      // Build 2074: see the XHTTP test above — the Transport
      // section starts below the build range now.
      await tester.scrollUntilVisible(
        find.widgetWithText(EmberChip, 'TCP'),
        120,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester
            .widget<EmberChip>(find.widgetWithText(EmberChip, 'TCP'))
            .selected,
        isTrue,
      );
    });

    testWidgets('network h2 opens as the HTTP/2 chip', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = _vless(network: 'h2');
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      // Build 2074: see the XHTTP test above — the Transport
      // section starts below the build range now.
      await tester.scrollUntilVisible(
        find.widgetWithText(EmberChip, 'HTTP/2'),
        120,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester
            .widget<EmberChip>(find.widgetWithText(EmberChip, 'HTTP/2'))
            .selected,
        isTrue,
      );
    });

    testWidgets('SS chacha20-poly1305 saves as chacha20-ietf-poly1305',
        (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = Profile(
        id: 'ss1',
        protocol: Protocol.shadowsocks,
        name: 'ss1',
        address: 'ss.example.com',
        port: 8388,
        uuidOrPassword: 'secret',
        method: 'chacha20-poly1305',
      );
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles.single.method, 'chacha20-ietf-poly1305');
    });

    testWidgets('SS aes-256-cfb saves as the aes-256-gcm default',
        (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = Profile(
        id: 'ss2',
        protocol: Protocol.shadowsocks,
        name: 'ss2',
        address: 'ss.example.com',
        port: 8388,
        uuidOrPassword: 'secret',
        method: 'aes-256-cfb',
      );
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles.single.method, 'aes-256-gcm');
    });

    testWidgets('Hy2 non-salamander obfs opens and saves as off',
        (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = Profile(
        id: 'hy1',
        protocol: Protocol.hysteria2,
        name: 'hy1',
        address: 'hy.example.com',
        port: 443,
        uuidOrPassword: 'secret',
        obfs: 'http',
      );
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles.single.obfs, isEmpty);
    });

    testWidgets('unknown gRPC mode opens as gun', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = _vless(network: 'grpc', mode: 'stream');
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      // Build 2074: see the XHTTP test above — the mode dropdown
      // sits in the Transport section, below the build range now.
      await tester.scrollUntilVisible(
        find.widgetWithText(EmberChip, 'gRPC'),
        120,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is DropdownButton<String> && w.value == 'gun',
        ),
        findsOneWidget,
      );
    });

    testWidgets('unknown fragment shape opens as Off', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = _vless(afFragment: 'f99');
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      // The Anti-filter section sits below the fold: the
      // ListView only builds it once scrolled into view.
      await tester.scrollUntilVisible(
        find.text('TLS fragmentation'),
        300,
        // The form's TextFields are Scrollables too: name the
        // ListView's own Scrollable, or the default finder
        // matches many.
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is DropdownButton<String> && w.value == '',
        ),
        findsOneWidget,
      );
    });
  });

  group('WARP Renew stays on the settings page', () {
    testWidgets('tapping Renew does not pop the route', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      // The renewal answers through the app/android channel
      // (WarpPlatform.renew/state): unmocked, those calls never
      // complete under fake async and the inline note never lands.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async => null,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app/android'),
              null,
            );
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WarpSettingsPage(xray: xray),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WarpSettingsPage), findsOneWidget);
      // The Identity section sits below the fold: the ListView
      // only builds it once scrolled into view, so ensureVisible
      // on the not-yet-built chip throws "No element".
      await tester.scrollUntilVisible(
        find.text('Renew WARP Key'),
        300,
        // The page's TextFields are Scrollables too: name the
        // ListView's own Scrollable, or the default finder
        // matches many.
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // scrollUntilVisible stops as soon as the chip is built
      // (the ListView's cache extent reaches below the fold),
      // so bring it on screen before tapping, or the tap
      // lands outside the 600 px viewport.
      await tester.ensureVisible(find.text('Renew WARP Key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Renew WARP Key'));
      await tester.pumpAndSettle();
      // Still on the page: the old Renew saved through _save,
      // whose pop closed the whole settings page.
      expect(find.byType(WarpSettingsPage), findsOneWidget);
      // The outcome is reported inline on the page (no native
      // core answers in a test, so the renewal fails honestly).
      expect(
        find.text(
          'The renewal did not complete — check the connection and '
          'try again.',
        ),
        findsOneWidget,
      );
    });
  });

  group('sign-in dialog fits a 360 px phone', () {
    testWidgets('credentials form lays out without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final core = CoreController(
        () async =>
            throw const CoreUnavailable(CoreProblem.refused, 'test'),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(core.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSignInDialog(context, core),
              child: const Text('add'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dialog = tester.getSize(find.byType(Dialog));
      expect(dialog.width, lessThanOrEqualTo(360));
    });

    testWidgets('a long email title is one ellipsised line',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final core = CoreController(
        () async =>
            throw const CoreUnavailable(CoreProblem.refused, 'test'),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(core.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSignInDialog(
                context,
                core,
                started: SignInState.fromJson(const {
                  'id': 's1',
                  'email':
                      'a-very-long-email-address-that-keeps-going@example.com',
                  'step': 'needEmailCode',
                  'message': '',
                  'error': '',
                  'error_code': '',
                  'password_accepted': false,
                  'captcha': '',
                  'account_id': '',
                  'auth_url': '',
                }),
              ),
              child: const Text('add'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final titles = tester
          .widgetList<Text>(
            find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  w.maxLines == 1 &&
                  w.overflow == TextOverflow.ellipsis,
            ),
          )
          .toList();
      expect(titles, hasLength(1));
      expect(titles.single.data, contains('a-very-long-email'));
    });
  });

  group('bootstrap relay fields use emberField (source pins)', () {
    test('no raw Material underline decoration remains', () {
      final dart = _dart('ui/ember/mozilla_bootstrap.dart');
      expect(dart, contains('emberField('));
      expect(dart, isNot(contains('InputDecoration(')));
      expect(dart, isNot(contains('UnderlineInputBorder')));
    });
  });

  group('A-H3 button language in the batch-12 files (source pins)', () {
    test('profile editor + bootstrap: no stock Material buttons', () {
      for (final path in [
        'ui/ember/profile_editor.dart',
        'ui/ember/mozilla_bootstrap.dart',
      ]) {
        final dart = _dart(path);
        expect(dart, isNot(contains('OutlinedButton')), reason: path);
        expect(dart, isNot(contains('FilledButton')), reason: path);
      }
    });
  });
}
