/// Build 2055 gates — audit Batch 7 remainder (battery:
/// B-H5 native supervisor loops, B-M1 stats-save debounce
/// remainder, B-M4 per-line log I/O) + Batch 8 remainder
/// (appearance: A-H4 lazy servers lists, A-H2 disabled-button
/// contrast — the A-H2 code landed in 2050 but was never
/// recorded in the progress file; it is verified + pinned here).
///
/// - B-H5: the supervisor loops tick at 5 s, not 1 s (Xray,
///   Psiphon, Lantern watchers; CoreService country/speed
///   10 s / 5 s). Every probe that was a modulo-5 check now
///   runs once per 5 s tick, so the three-failure budgets
///   stay ~15 s. Source pins (loop timing is a device property).
/// - B-M1: the 30 s debounce + disconnect flush landed in
///   2050; the remainder is the BACKGROUND flush — the shell
///   lands pending totals when the app leaves the foreground,
///   so a killed backgrounded app loses no tail. Behavioural:
///   the flush is a no-op when nothing is pending (no I/O on
///   an idle tunnel).
/// - B-M4: one buffered writer per log (flush on 2 s timer or
///   8 KB) in Lantern / Psiphon / OpenVPN; EmberWarp tails
///   only new bytes via RandomAccessFile; the Aether prober
///   runs at debug, not trace. Source pins.
/// - A-H4: V2Ray / Mozilla / OpenVPN lists are slivers with
///   lazily built rows (behavioural laziness test: with 60
///   configs only the on-screen rows exist). The header panel
///   keeps its MapGlass; rows keep their _SubRow cards.
/// - A-H2: a disabled EmberButton renders its label and icon
///   in Ember.dim (widget test).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/core/core_api.dart';
import 'package:firefox_vpn/core/core_controller.dart';
import 'package:firefox_vpn/l10n/app_localizations.dart';
import 'package:firefox_vpn/ui/ember/ember_servers.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/xray/xray_controller.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

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

String _read(String path) => File(path).readAsStringSync();

String _kt(String name) => _read(
  'android/app/src/main/kotlin/com/ralysnd/ember/$name',
);

String _dart(String path) => _read('lib/$path');

void main() {
  group('B-H5 native supervisor loops at 5 s (source pins)', () {
    test('Xray watchProcesses: 5 s loop, every probe per tick', () {
      final kt = _kt('XrayVpnService.kt');
      expect(kt, contains('Thread.sleep(5000)'));
      expect(kt, contains('tick++'));
      // No probe may still be gated on a 1 s tick modulus:
      // the loop is 5 s now, so each check runs once per tick.
      expect(kt, isNot(contains('tick % 6 == 0')));
      expect(kt, isNot(contains('tick % 5 == 0')));
      expect(kt, isNot(contains('++tick % 6')));
      expect(kt, isNot(contains('++tick % 5')));
    });

    test('Psiphon watchBridge: 5 s loop (build 2091: the '
        'watchHelper is gone with the sidecar; the bridge '
        'watcher keeps the 5 s B-H5 loop)', () {
      final kt = _kt('PsiphonVpnService.kt');
      // The supervisor loop is watchBridge now: it polls the
      // in-process badvpn bridge every 5 s and tears the
      // session down when the bridge is gone.
      expect(kt, contains('private fun watchBridge()'));
      expect(kt, contains('Thread.sleep(5000)'));
      expect(kt,
          contains('bridgeStarted && !Tun2SocksManager.isRunning'));
    });

    test('Lantern status poll: 3.5 s core-verdict loop (2129)', () {
      // Superseded in build 2129: the CLI supervisor loop is
      // gone with the subprocess; the gomobile shape polls
      // the core's own isVPNConnected verdict at LML's 3.5 s
      // cadence instead.
      final kt = _kt('LanternVpnService.kt');
      expect(kt, contains('STATUS_POLL_MS = 3_500L'));
      expect(kt, contains('Thread.sleep(STATUS_POLL_MS)'));
      expect(kt, isNot(contains('fun watchProcesses')));
    });

    test('CoreService: country 10 s, speed 5 s', () {
      final kt = _kt('CoreService.kt');
      expect(kt, contains('COUNTRY_POLL_MS = 10000L'));
      expect(kt, contains('SPEED_POLL_MS = 5000L'));
      expect(kt, isNot(contains('COUNTRY_POLL_MS = 3000L')));
      expect(kt, isNot(contains('SPEED_POLL_MS = 2000L')));
    });
  });

  group('B-M1 stats-save background flush', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ember2055-stats-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            (call) async {
              if (call.method == 'dataDir') return '${tempDir.path}/core';
              return null;
            },
          );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            null,
          );
      await tempDir.delete(recursive: true);
    });

    test('flush with nothing pending writes nothing', () async {
      final c = XrayController();
      addTearDown(c.dispose);
      await c.flushStatsOnBackground();
      // No state.json appears: the flush gates on the pending
      // flag, so an idle tunnel costs no I/O.
      expect(
        await Directory(tempDir.path).list(recursive: true).toList(),
        isEmpty,
      );
    });

    test('the shell wires the flush to the lifecycle', () {
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(shell, contains('flushStatsOnBackground'));
      expect(
        shell,
        contains('if (!_foreground) unawaited(_xray.flushStatsOnBackground());'),
      );
      final ctl = _dart('xray/xray_controller.dart');
      expect(
        ctl,
        contains('Future<void> flushStatsOnBackground() => _flushStatsSave();'),
      );
      expect(ctl, contains('if (!_statsSavePending) return;'));
    });
  });

  group('B-M4 buffered log writers (source pins)', () {
    test('Lantern logs: the gomobile core writes its own files (2129)', () {
      // Superseded in build 2129: there is no stdout to drain
      // — the core logs to its Opts logDir (filesDir/lantern/
      // logs), which the diagnostics export reads.
      final kt = _kt('LanternVpnService.kt');
      expect(kt, isNot(contains('bytesSinceFlush')));
      final bridge = File(
        'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/LanternEngine.java',
      ).readAsStringSync();
      expect(bridge, contains('opts.setLogDir'));
      expect(bridge, contains('opts.setLogLevel("error")'));
    });

    test('Psiphon: one held writer, closed on stop', () {
      final kt = _kt('PsiphonVpnService.kt');
      expect(kt, contains('logWriter = FileOutputStream(f, true).bufferedWriter()'));
      expect(kt, contains('logBytesSinceFlush >= 8192'));
      expect(kt, contains('closeLogLocked()'));
      expect(kt, contains('synchronized(logLock) { closeLogLocked() }'));
    });

    test('OpenVPN: one held writer in OpenVpnCore, closed at session end', () {
      final kt = _kt('OpenVpnService.kt');
      expect(kt, contains('private var logWriter: java.io.BufferedWriter? = null'));
      expect(kt, contains('logBytesSinceFlush >= 8192'));
      expect(kt, contains('fun closeLog()'));
      expect(kt, contains('OpenVpnCore.closeLog()'));
      expect(
        kt,
        isNot(contains('FileOutputStream(file, true).bufferedWriter().use {')),
      );
    });

    test('EmberWarp watchLog: offset tail read, no whole-file reread', () {
      final kt = _kt('EmberWarpCore.kt');
      expect(kt, contains('RandomAccessFile(file, "r")'));
      expect(kt, contains('raf.seek(start)'));
      // Scoped to watchLog: renew() legitimately reads the whole
      // log once while registering a fresh identity. watchLog is
      // the last private fun in the file; the next function after
      // it is the public stop().
      final start = kt.indexOf('private fun watchLog');
      final end = kt.indexOf('fun stop()', start);
      final watchLog = kt.substring(start, end);
      expect(watchLog, isNot(contains('file.readText()')));
      expect(watchLog, isNot(contains('readText()')));
    });

    test('Aether prober: debug, not trace', () {
      final kt = _kt('AetherCore.kt');
      expect(kt, contains('aether::prober=debug'));
      expect(kt, isNot(contains('aether::prober=trace')));
    });
  });

  group('A-H2 disabled EmberButton contrast (widget)', () {
    testWidgets('a disabled button renders label and icon in Ember.dim',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmberButton(
              label: 'Import',
              icon: Icons.content_paste_rounded,
              onTap: null,
            ),
          ),
        ),
      );
      await tester.pump();
      final icon = tester.widget<Icon>(find.byType(Icon).first);
      expect(icon.color, Ember.dim);
      final text = tester.widget<Text>(find.text('Import'));
      expect(text.style?.color, Ember.dim);
    });
  });

  group('A-H4 servers lists are slivers with lazy rows', () {
    test('V2Ray + Mozilla lists: CustomScrollView + SliverList, no ListView', () {
      final dart = _dart('ui/ember/ember_servers.dart');
      expect(dart, contains('CustomScrollView('));
      expect(dart, contains('SliverList('));
      expect(dart, contains('SliverChildBuilderDelegate('));
      expect(dart, isNot(contains('ListView(')));
    });

    test('OpenVPN profiles list: slivers too', () {
      final dart = _dart('ui/ember/openvpn_pages.dart');
      expect(dart, contains('Build 2055 (audit A-H4): slivers'));
      expect(dart, contains('SliverList('));
    });

    testWidgets('60 configs: only on-screen rows are built', (tester) async {
      final xray = XrayController();
      addTearDown(xray.dispose);
      xray.profiles = [
        for (var i = 0; i < 60; i++)
          _vless('cfg-${i.toString().padLeft(2, '0')}', 's$i.example.com'),
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
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byType(SliverList), findsOneWidget);
      // The first row is built; a row far down the list is not —
      // the old eager Column built all 60 up front.
      expect(find.text('cfg-00'), findsOneWidget);
      expect(find.text('cfg-59'), findsNothing);
    });
  });
}
