/// Build 2057 gates — audit Batch 14 remainder (tests honesty +
/// remaining mediums):
///
/// - F-H10: the accepted -8 test baseline — the perpetual pulse
///   animations now respect MediaQuery.disableAnimations (actors
///   layer, world map, power ring), and the shell's first-run flag
///   writes land after the frame instead of notifying mid-build.
///   Behavioural widget tests + source pins; the stale expectations
///   themselves were corrected in widget_test.dart / core_api_test.dart.
/// - F-M4: Psiphon — the IPv6 extra is threaded (service honours it,
///   Dart sends it), the watcher tears down a silently dead core,
///   and Dart connect() requires `connected` in VPN mode.
/// - F-M7: xray.log / tunlink.log rotate to .old past 1 MB at every
///   start/restart append site (service + tester).
/// - F-M17: Android Auto Backup excludes every known secret path.
///
/// Kotlin/XML fixes are source-pinned (no androidTest source set
/// exists); the Psiphon connect() behaviour is tested through the
/// method channel. The connected-wait budget is source-pinned
/// (a real-time test of the full budget would take minutes); the
/// timeout path itself is driven behaviourally through the
/// core-dies branch.
///
/// Build 2067 supersession (recorded, not silent): the F-M7 pin
/// below accepts rotateLogPerSession alongside rotateLogIfLarge
/// as the guard above an append site. The invariant is unchanged
/// (no append site without a rotation guard; logs cannot grow
/// unboundedly) — for tunlink.log the guard became STRONGER:
/// rotation at every session start instead of only past 1 MB,
/// so a previous session's flood can never be read as the
/// current one (the log-hygiene fix of the 2066 device report).
///
/// Build 2065 supersession (recorded, not silent): the budget pin
/// moved 440 → 1200 polls (110 s → 300 s) because the Psiphon
/// strategy ladder's worst case (25 s region phase + rungs
/// 60+45+45+75 s = 250 s) exceeds the old single-attempt budget —
/// the bounded wait and the connect-timeout throw the pin
/// protects are unchanged. The watchHelper positional pin was
/// re-anchored to the VPN bridging code for the same reason: the
/// ladder restructure grew the proxy-only branch a comment, and
/// the protected behaviour (proxy-only mode is watched) is
/// unchanged.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';

String _read(String path) => File(path).readAsStringSync();

String _kt(String name) =>
    _read('android/app/src/main/kotlin/com/ralysnd/ember/$name');

String _dart(String path) => _read('lib/$path');

/// The test harness's "reduce motion", as widget_test.dart's
/// stillMotion does it.
void _stillMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void main() {
  group('F-H10 pulse respects disableAnimations', () {
    testWidgets('PowerRing stays still when animations are disabled', (
      tester,
    ) async {
      _stillMotion(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: PowerRing(on: true, busy: false, onTap: () {}),
        ),
      );
      // A repeating controller never settles: this returns only
      // because the ring honours disableAnimations.
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
    });

    testWidgets('PowerRing animates when animations are on (control)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PowerRing(on: true, busy: false, onTap: () {}),
        ),
      );
      // The control proves the still test above can detect the bug:
      // with animations on, the ring repeats and pumpAndSettle
      // times out.
      var timedOut = false;
      try {
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 2),
        );
      } on FlutterError {
        timedOut = true;
      }
      expect(timedOut, isTrue);
    });

    // Build 2071 (review §5.5): the 'WorldMapPanel stays
    // still' widget test is REMOVED with the widget itself —
    // WorldMapPanel had no production caller (the live map
    // is MapBackdropVisual/MapActorsPainter) and was deleted
    // as dead weight; its pulse controller went with it, so
    // the pin below now covers the two remaining controllers.

    test('all pulse controllers check disableAnimations', () {
      for (final (path, owner) in [
        ('ui/ember/ember_shell.dart', '_ActorsLayerState'),
        ('ui/ember/ember_theme.dart', '_PowerRingState'),
      ]) {
        final src = _dart(path);
        expect(
          src.contains('disableAnimations'),
          isTrue,
          reason: '$owner in $path must honour disableAnimations',
        );
      }
    });

    test('the engine rail is the restored pre-2074 stack', () {
      // Build 2075 (owner-ordered revert): the owner disliked
      // build 2074's horizontal scrolling strip and ordered the
      // previous build's engine-selector layout back — the
      // nine chips stacked at the header's top-right in a Wrap,
      // folding to two columns on short windows (compactRail,
      // the build 2057 mechanism). 2074's scroller machinery is
      // gone; every other 2074 UI fix stands.
      // PIN UPDATED by build 2147 (fix item #23, owner device
      // verdict 2026-11-24 on shipped 2146): the stacked tower
      // is superseded by the owner's newer order — on non-Home
      // tabs the header is now slim (the Home brand line + ONE
      // horizontal, scrollable chip row), so the pins below
      // follow the intentional change: the horizontal strip is
      // back by order, the Wrap stack and compactRail are gone.
      final src = _dart('ui/ember/ember_shell.dart');
      expect(src.contains('scrollDirection: Axis.horizontal'), isTrue);
      expect(src.contains('_railController'), isFalse);
      expect(src.contains('compactRail'), isFalse);
      expect(
        src.contains('Wrap(spacing: 6, runSpacing: 0, children: rail)'),
        isFalse,
      );
    });
  });

  group('F-H10 setState-during-build fix', () {
    test('first-run flag writes land after the frame, not mid-build', () {
      final src = _dart('ui/ember/ember_shell.dart');
      // Both async first-run writers must defer their
      // AppSettings.update() past the frame — a notifyListeners()
      // from an async continuation can land inside a build and
      // throw on the shell's ListenableBuilders (widget_test:1693).
      for (final flag in [
        'ember2DefaultsApplied: true',
        'transportPinned: true',
      ]) {
        final at = src.indexOf(flag);
        expect(at, isNot(-1), reason: '$flag must still be written');
        final window = src.substring(
          (at - 600).clamp(0, src.length),
          at,
        );
        expect(
          window.contains('addPostFrameCallback'),
          isTrue,
          reason: '$flag must be written from a post-frame callback',
        );
      }
    });
  });

  group('F-M4 Psiphon IPv6 extra', () {
    // Build 2123 supersession (recorded, not silent): S-3
    // of the Psiphon fix plan replaced the 2091 posture.
    // The extra is still carried and still not read back,
    // but the TUN now CAPTURES IPv6 (ULA address + ::/0)
    // and drops it — the v4-only bridge has no v6 egress,
    // so capture-and-drop is the leak fix (audit P-04);
    // before 2123 the family simply bypassed the tunnel.
    test('service captures IPv6 and drops it (build 2123: '
        'S-3 capture-and-drop; bridge stays IPv4-only)', () {
      final src = _kt('PsiphonVpnService.kt');
      expect(src.contains('EXTRA_IPV6 = "ipv6"'), isTrue);
      expect(src.contains('putExtra(EXTRA_IPV6, ipv6)'), isTrue);
      // The flag stays threaded but inert: capture is
      // unconditional, so the host still never reads it.
      expect(src.contains('getBooleanExtra(EXTRA_IPV6'), isFalse);
      // Xray's ULA is not Psiphon's; Psiphon uses MLM's.
      expect(src.contains('fdfe:dcba:9876::1'), isFalse);
      expect(src.contains('addRoute("::", 0)'), isTrue);
      expect(src.contains('addAddress(IPV6_BLACKHOLE, 128)'), isTrue);
      expect(src.contains('if (ipv6) {'), isFalse);
    });

    test('Dart sends the setting and the shell wires it to ipv6Route', () {
      final platform = _dart('psiphon/psiphon_platform.dart');
      expect(platform.contains("'ipv6': ipv6"), isTrue);
      final controller = _dart('psiphon/psiphon_controller.dart');
      expect(controller.contains('tunnelIpv6'), isTrue);
      expect(controller.contains('ipv6: tunnelIpv6()'), isTrue);
      final shell = _dart('ui/ember/ember_shell.dart');
      expect(
        shell.contains('_psiphon.tunnelIpv6 = () => _xray.settings.ipv6Route'),
        isTrue,
      );
    });
  });

  group('F-M4 Psiphon core liveness', () {
    test('watchBridge tears down a silently dead bridge; '
        'the wedge is the external watchdog\u2019s (build 2091)', () {
      final src = _kt('PsiphonVpnService.kt');
      // Build 2091 supersession (recorded, not silent): the
      // provider is an in-process library again, so liveness
      // is twofold — the bridge watcher (a dead bridge tears
      // the session down) and the external watchdog (a wedged
      // start is killed from outside; startReturned is the
      // discriminator it reads).
      expect(src.contains('providerExited'), isFalse);
      expect(src.contains('coreExited'), isFalse);
      expect(src.contains('attemptExited'), isFalse);
      // The backstop for a rung that never connects is the
      // ladder timer (budget + 8 s grace), not a plain
      // connect deadline. The notice-silence pair is GONE
      // with the sidecar (the library's notices are the
      // record again) — pinned absent here and in
      // build2087's suite.
      expect(src.contains('CONNECT_DEADLINE_MS'), isFalse);
      expect(src.contains('NOTICE_SILENCE_MS'), isFalse);
      expect(src.contains('lastNoticeMs'), isFalse);
      expect(src.contains('armLadderTimer()'), isTrue);
      expect(src.contains('startReturned'), isTrue);
      // The bridge watcher runs in VPN mode, after the TUN
      // exists and the core starts.
      expect(src.contains('private fun watchBridge()'), isTrue);
      expect(
        src.contains('bridgeStarted && !Tun2SocksManager.isRunning'),
        isTrue,
      );
      expect(
        src.contains('psiphon bridge exited; tearing the session down'),
        isTrue,
      );
      final start = src.indexOf('startPsiphonTunnel()');
      final watch = src.indexOf('watchBridge()', start);
      expect(watch, isNot(-1));
    });
  });

  group('F-M4 Dart connect() requires connected in VPN mode', () {
    var mockPsiphonSetOnArgs = <String, dynamic>{};

    /// A mock 'app/android' channel answering psiphonState from a
    /// script: each entry is one state() answer in order; the last
    /// entry repeats.
    void mockPsiphon(List<Map<String, Object?>> script, void Function() onStop) {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      var setOnArgs = <String, dynamic>{};
      messenger.setMockMethodCallHandler(
        const MethodChannel('app/android'),
        (call) async {
          switch (call.method) {
            case 'psiphonSetOn':
              setOnArgs = Map<String, dynamic>.from(
                call.arguments as Map,
              );
              // The success test reads the recorded args through this.
              mockPsiphonSetOnArgs = setOnArgs;
              return null;
            case 'psiphonState':
              final entry =
                  script[calls < script.length ? calls : script.length - 1];
              calls++;
              return entry;
            case 'psiphonStop':
              onStop();
              return null;
            default:
              return null;
          }
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('app/android'),
          null,
        ),
      );
    }

    Map<String, Object?> psiphonState({
      required bool running,
      required bool connected,
      bool vpnMode = true,
    }) => {
      'running': running,
      'connected': connected,
      'vpnMode': vpnMode,
      'sinceMs': 0,
      'up': 0,
      'down': 0,
      'region': '',
      'clientAddress': '',
      'regions': <String>[],
    };

    test('connect() waits for connected and sends ipv6=false', () async {
      var stopCalls = 0;
      mockPsiphon([
        psiphonState(running: true, connected: false),
        psiphonState(running: true, connected: false),
        psiphonState(running: true, connected: true),
      ], () => stopCalls++);
      final c = PsiphonController()..tunnelIpv6 = () => false;
      try {
        // The old code returned after the first sample (running);
        // this returns only once the core reports connected.
        await c.connect();
        expect(mockPsiphonSetOnArgs['ipv6'], isFalse);
        expect(stopCalls, 0);
      } finally {
        c.dispose();
      }
    });

    test('the connected-wait budget is 1200 polls of 250 ms '
        '(~300 s; build 2065 ladder supersession)', () {
      final src = _dart('psiphon/psiphon_controller.dart');
      expect(src.contains('for (var i = 0; i < 1200; i++)'), isTrue);
      // Build 2090 supersession: the timeout error now carries the
      // psiphon.log tail (evidence-carrying establishment failure)
      // instead of the bare literal — the throw is a conditional
      // between the bare text and the tail-carrying text.
      expect(
        src.contains("'connect-timeout — the Psiphon log tail:"),
        isTrue,
      );
    });

    test('connect() times out, stops the dead core, and reports it', () async {
      var stopCalls = 0;
      mockPsiphon([
        psiphonState(running: true, connected: false),
        psiphonState(running: true, connected: false),
        // The core then dies without ever connecting: the old code
        // had already returned success here and left a TUN-up
        // blackhole behind.
        psiphonState(running: false, connected: false),
      ], () => stopCalls++);
      final c = PsiphonController();
      try {
        Object? error;
        try {
          await c.connect();
        } catch (e) {
          error = e;
        }
        expect(error, isA<StateError>());
        expect((error as StateError).message, 'connect-timeout');
        expect(stopCalls, greaterThan(0));
      } finally {
        c.dispose();
      }
    });

    test('proxy-only mode waits for connected too (build '
        '2091: the R12 contract change)', () async {
      // Build 2091: success means the CORE connected, not
      // the process running — in proxy mode as in VPN mode.
      // A proxy-only core that never connects times out
      // exactly like a VPN-mode one (and is stopped, like
      // one). The old "running alone is enough" shape is
      // gone with the sidecar it described.
      var stopCalls = 0;
      mockPsiphon([
        psiphonState(running: true, connected: false, vpnMode: false),
        psiphonState(running: true, connected: false, vpnMode: false),
        // The core then dies without ever connecting.
        psiphonState(running: false, connected: false, vpnMode: false),
      ], () => stopCalls++);
      final c = PsiphonController()..settings.vpnMode = false;
      Object? error;
      try {
        await c.connect();
      } catch (e) {
        error = e;
      } finally {
        c.dispose();
      }
      expect(error, isA<StateError>());
      expect((error as StateError).message, 'connect-timeout');
      expect(stopCalls, greaterThan(0));
    });

    test('proxy-only mode succeeds once the core connects',
        () async {
      mockPsiphon([
        psiphonState(running: true, connected: false, vpnMode: false),
        psiphonState(running: true, connected: true, vpnMode: false),
      ], () {});
      final c = PsiphonController()..settings.vpnMode = false;
      try {
        await c.connect();
      } finally {
        c.dispose();
      }
    });
  });

  group('F-M7 log rotation at every appendTo', () {
    test('every appendTo has a rotation guard just above it', () {
      for (final name in ['XrayVpnService.kt', 'XrayTester.kt']) {
        final lines = _kt(name).split('\n');
        var appends = 0;
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('Redirect.appendTo')) continue;
          appends++;
          final window = lines
              .sublist((i - 12).clamp(0, lines.length), i)
              .join('\n');
          expect(
            // Build 2067 supersession (see header): the 1 MB
            // size guard, or the stronger per-session rotation
            // tunlink.log now uses.
            window.contains('rotateLogIfLarge') ||
                window.contains('rotateLogPerSession'),
            isTrue,
            reason: '$name:${i + 1} appends without a rotation guard above it',
          );
        }
        expect(appends, greaterThan(0), reason: '$name has no appendTo');
      }
    });

    test('rotation renames to .old past exactly 1 MB', () {
      for (final name in ['XrayVpnService.kt', 'XrayTester.kt']) {
        final src = _kt(name);
        expect(src.contains('1024 * 1024'), isTrue, reason: name);
        expect(src.contains(r'${file.name}.old'), isTrue, reason: name);
      }
    });
  });

  group('F-M17 backup excludes every known secret path', () {
    // A directory exclusion covers everything under it (the
    // accounts dir holds one credentials.json + pass.json per
    // account), so the per-file secrets are asserted through it.
    const secrets = [
      'xray/state.json',
      'core/config.json',
      'core/accounts/',
      'openvpn/state.json',
    ];

    test('backup_rules.xml excludes the secret stores', () {
      final xml = _read('android/app/src/main/res/xml/backup_rules.xml');
      for (final path in secrets) {
        expect(
          xml.contains('<exclude domain="file" path="$path" />'),
          isTrue,
          reason: 'backup_rules.xml must exclude $path',
        );
      }
    });

    test('data_extraction_rules.xml excludes them in both sections', () {
      final xml = _read(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );
      for (final section in ['cloud-backup', 'device-transfer']) {
        final start = xml.indexOf('<$section>');
        final end = xml.indexOf('</$section>');
        expect(start, isNot(-1), reason: 'missing <$section>');
        final body = xml.substring(start, end);
        for (final path in secrets) {
          expect(
            body.contains('<exclude domain="file" path="$path" />'),
            isTrue,
            reason: '<$section> must exclude $path',
          );
        }
      }
    });

    test('the old non-secret exclusions are untouched', () {
      for (final file in [
        'android/app/src/main/res/xml/backup_rules.xml',
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ]) {
        final xml = _read(file);
        for (final path in [
          'core/logs/',
          'core/routing/',
          'core/servers.json',
          'core/status.json',
          'core/local-api.token',
        ]) {
          expect(
            xml.contains('path="$path"'),
            isTrue,
            reason: '$file lost its $path exclusion',
          );
        }
      }
    });
  });
}
