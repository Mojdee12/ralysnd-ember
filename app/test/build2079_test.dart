import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/profile_editor.dart';
import 'package:firefox_vpn/xray/anti_filter.dart';
import 'package:firefox_vpn/xray/config_builder.dart';
import 'package:firefox_vpn/xray/link_parser.dart';
import 'package:firefox_vpn/xray/profile_codec.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

/// Build 2079 — feature queue #10: the Mirage mask as a full
/// run-mode (a first-class fragment shape), not a paste-in
/// preset.
///
/// Core support was verified FIRST, from the bundled core's own
/// source (toolchain/gopath module cache, xtls/xray-core
/// @v1.260327.1-0.20260930074004-b26a91de4f32 — the same core
/// libxray.so is built from), not taken on the feature list's
/// word:
/// - There is NO mask type literally named 'mirage': the TCP
///   mask loader (infra/conf/transport_finalmask.go,
///   tcpmaskLoader) knows header-custom / fragment / sudoku /
///   xmc, the UDP loader noise / salamander / sudoku / xdns /
///   xicmp / realm / udphop / mkcp-legacy — no 'mirage' in
///   either, and zero 'mirage' hits in the whole finalmask
///   tree. No core bump can add one; none is needed.
/// - The Mirage mechanism IS the fragment mask's tlshello pass:
///   FragmentMask.Build() maps packets "tlshello" to
///   PacketsFrom 0 / PacketsTo 1 and rejects only a zero LAST
///   lengths entry — lengths ["0","104","1"] pass (last min 1),
///   delays ["0"] and maxSplit "0" (uncapped) pass. The
///   fragment conn's tlshello branch splits the first TLS
///   record (type 22) into per-length records, and a single
///   zero delay merges them into ONE write (mergeTlsHello
///   Segments) — the filter never sees a whole hello, with no
///   per-record timing side-channel.
/// - Host-validated with the packaged core's host binary
///   (xray-host 26.10.29): a config carrying exactly this
///   finalmask answers `run -test` with "Configuration OK.",
///   and a live run answers a SOCKS greeting [5, 0].
/// What a filtered network actually does with the split hello
/// is decidable only on the owner's phone — this build proves
/// the shape is real, wired, and accepted by the core.
///
/// What changed: 'mirage' joins afFragmentShapes, so the
/// editor's TLS fragmentation dropdown offers it by name, the
/// profile stores it like any other shape, the builder emits
/// it, and the identity link carries it. The 2075 'Mirage
/// mask' paste chip is deleted — the dropdown shape replaces
/// it (the raw finalMask field stays for custom JSON, and a
/// profile that pasted the old JSON still builds the same
/// mask).

Profile _tls({
  String afFragment = '',
  String security = 'tls',
  String finalMask = '',
}) =>
    Profile(
      id: 'm1',
      protocol: Protocol.vless,
      name: 'm',
      address: 'm.example.com',
      port: 443,
      uuidOrPassword: '00000000-0000-4000-8000-000000000000',
      network: 'ws',
      host: 'm.example.com',
      security: security,
      sni: 'm.example.com',
      afFragment: afFragment,
      finalMask: finalMask,
    );

Map<String, dynamic> _baseStream() => <String, dynamic>{
      'network': 'ws',
      'security': 'tls',
      'tlsSettings': <String, dynamic>{
        'serverName': 'm.example.com',
        'fingerprint': 'chrome',
      },
      'wsSettings': <String, dynamic>{
        'headers': <String, dynamic>{'Host': 'm.example.com'},
      },
    };

Map<String, dynamic> _decode(Profile p) =>
    jsonDecode(buildTestConfig(p, XraySettings())) as Map<String, dynamic>;

Map<String, dynamic> _proxyOutbound(Map<String, dynamic> cfg) =>
    (cfg['outbounds'] as List<dynamic>)
        .firstWhere((o) => (o as Map)['tag'] == 'proxy')
        as Map<String, dynamic>;

List<dynamic> _maskTcp(Map<String, dynamic> stream) =>
    ((stream['finalmask'] as Map)['tcp'] as List<dynamic>);

Finder _listScrollable() => find
    .descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    )
    .first;

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
  group('mirage shape', () {
    test('mirage is in the catalogue with its mechanism values', () {
      final shape = afShapeById('mirage');
      expect(shape, isNotNull);
      expect(shape!.label, 'Mirage · ClientHello split');
      expect(shape.lengths, ['0', '104', '1']);
      expect(shape.delays, ['0']);
      expect(shape.maxSplit, '0');
      // First in the dropdown: the named technique, not buried
      // after the F-recipes.
      expect(afFragmentShapes.first.id, 'mirage');
    });

    test('the shape emits exactly the canonical Mirage JSON', () {
      final shape = afShapeById('mirage')!;
      final canonical =
          jsonDecode(mirageFinalMaskJson) as Map<String, dynamic>;
      expect(
        jsonEncode({'tcp': [shape.entry()]}),
        jsonEncode(canonical),
      );
      final settings = shape.entry()['settings'] as Map<String, dynamic>;
      expect(settings['packets'], 'tlshello');
      expect(settings['lengths'], ['0', '104', '1']);
      expect(settings['delays'], ['0']);
      expect(settings['maxSplit'], '0');
    });
  });

  group('applyAntiFilter: mirage', () {
    test('mirage alone splits the hello and touches nothing else', () {
      final stream = _baseStream();
      applyAntiFilter(stream, _tls(afFragment: 'mirage'));
      final tcp = _maskTcp(stream);
      expect(tcp.length, 1);
      expect(
        jsonEncode(tcp.single),
        jsonEncode(jsonDecode(mirageFinalMaskJson)['tcp'].single),
      );
      // Unlike unfilter, Mirage changes NO fingerprint and NO
      // cipher suites: only the ClientHello split.
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['fingerprint'], 'chrome');
      expect(tls.containsKey('cipherSuites'), isFalse);
      expect(tls.containsKey('echConfigList'), isFalse);
    });

    test('mirage beats the unfilter default mask', () {
      final stream = _baseStream();
      final p = _tls(afFragment: 'mirage')..afUnfilter = true;
      applyAntiFilter(stream, p);
      final tcp = _maskTcp(stream);
      expect(tcp.length, 1);
      expect(
        jsonEncode(tcp.single),
        jsonEncode(jsonDecode(mirageFinalMaskJson)['tcp'].single),
      );
      // The unfilter ciphers still ride — only its two-pass
      // mask is replaced by the single Mirage pass.
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['cipherSuites'], afUnfilterCipherSuites);
      expect(tls['fingerprint'], 'unsafe');
    });

    test('ECH beats mirage', () {
      final stream = _baseStream();
      final p = _tls(afFragment: 'mirage')..afEch = true;
      applyAntiFilter(stream, p);
      expect(stream.containsKey('finalmask'), isFalse);
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      expect(tls['echConfigList'], afEchConfigList);
    });

    test('mirage is TLS-only', () {
      for (final security in ['reality', '']) {
        final stream = _baseStream()..['security'] = security;
        applyAntiFilter(
          stream,
          _tls(afFragment: 'mirage', security: security),
        );
        expect(stream.containsKey('finalmask'), isFalse, reason: security);
      }
    });
  });

  group('built config', () {
    test('the mirage mask lands in the built config', () {
      final out = _proxyOutbound(_decode(_tls(afFragment: 'mirage')));
      final stream = out['streamSettings'] as Map<String, dynamic>;
      final tcp = _maskTcp(stream);
      expect(tcp.length, 1);
      expect(
        jsonEncode(tcp.single),
        jsonEncode(jsonDecode(mirageFinalMaskJson)['tcp'].single),
      );
    });

    test('a pasted Mirage JSON still builds the same mask', () {
      // Legacy: a profile that pasted the 2075 preset into
      // finalMask keeps working — the merge path is unchanged.
      final out = _proxyOutbound(
        _decode(_tls(finalMask: mirageFinalMaskJson)),
      );
      final stream = out['streamSettings'] as Map<String, dynamic>;
      final tcp = _maskTcp(stream);
      expect(tcp.length, 1);
      expect(
        jsonEncode(tcp.single),
        jsonEncode(jsonDecode(mirageFinalMaskJson)['tcp'].single),
      );
    });
  });

  group('codec', () {
    test('the identity link round-trips the mirage shape', () {
      final p = _tls(afFragment: 'mirage');
      final link = profileToLink(p);
      expect(link, contains('afFragment=mirage'));
      final back = parseLink(link)!;
      expect(back.afFragment, 'mirage');
      expect(back.protocol, Protocol.vless);
    });
  });

  group('editor', () {
    testWidgets('picking Mirage in the dropdown saves the shape',
        (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      // Save gates shaped profiles on the core itself
      // (XrayPlatform.validateConfig over the app/android
      // channel): unmocked, that call never completes under
      // fake async and the save hangs (build 2056 pattern).
      // null = the core accepts the config.
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
      final p = _tls();
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      expect(find.byType(ProfileEditorPage), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('TLS fragmentation'),
        300,
        scrollable: _listScrollable(),
      );
      // Build 2095 harness repair: the editor grew
      // (transport fields), and scrollUntilVisible now
      // parks the dropdown row half under the transparent
      // app bar (its rect starts at y=-15) — the menu
      // opens clipped and its items never render. The
      // build-2053 drag (+120) parks the row fully below
      // the app bar's hit zone first.
      await tester.drag(find.byType(ListView).first, const Offset(0, 120));
      await tester.pumpAndSettle();
      final dropdown = find.descendant(
        of: find.ancestor(
          of: find.text('TLS fragmentation'),
          matching: find.byType(Row),
        ),
        matching: find.byType(DropdownButton<String>),
      );
      expect(dropdown, findsOneWidget);
      // Open the menu with plain pumps: the menu route keeps a
      // ticker alive that pumpAndSettle waits on. (No drag
      // here: scrollUntilVisible already leaves the dropdown
      // tappable — the 2053 drag pattern parks it under the
      // transparent app bar again via ensureVisible.)
      await tester.tap(dropdown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Mirage · ClientHello split'), findsOneWidget);
      await tester.tap(find.text('Mirage · ClientHello split'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(xray.profiles, hasLength(1));
      expect(xray.profiles.single.afFragment, 'mirage');
    });

    testWidgets('the Mirage mask paste chip is gone', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      final p = _tls();
      xray.profiles.add(p);
      await _pumpEditor(tester, xray, p);
      // Scroll to the preset chips, not to the field label:
      // find.text('Finalmask (JSON)') matches the label twice
      // (the decoration renders it in two places), so
      // scrollUntilVisible's single-element lookup throws.
      await tester.scrollUntilVisible(
        find.text('Merge preset'),
        300,
        scrollable: _listScrollable(),
      );
      // The 2075 paste chip was replaced by the dropdown
      // shape; the Merge preset and Clear chips stay.
      expect(find.text('Mirage mask'), findsNothing);
      expect(find.text('Merge preset'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });
  });
}
