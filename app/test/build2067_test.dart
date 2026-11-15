// Build 2067 — Psiphon start-path hardening + log hygiene.
//
// Owner device report on 2066 (2026-11-14 ~22:12 Tehran): tapping
// Psiphon Connect killed the whole app instantly and psiphon.log
// was EMPTY — the crash was before PsiphonVpnService.startTunnel.
// Diagnosis (2066-crash-diagnosis.md), CONFIRMED by the owner
// (~22:22, «اره از اول ریختم» — a fresh install): a fresh install
// revokes the VPN consent every upgrade used to carry, so the tap
// took the consent branch in MainActivity's channel handler —
// VpnService.prepare(), startActivityForResult, and the deferred
// startForegroundService from onActivityResult — which ran with
// NO try/catch anywhere around it (the handler has no outer
// guard). Any native throw there was an uncaught main-thread
// death: app gone, no Dart error, no log. Shir o Khorshid (the
// device-proven reference) treats prepare() itself as throwable.
//
// The fix: every engine's start handoff in the handler now runs
// through MainActivity.startVpnGuarded (or, for the Mozilla
// branch whose start replies itself, the same guard spelled out
// — build 2070 later routed that branch through the helper too;
// see the updated pins below), and onActivityResult's deferred
// starts run through runDeferredVpnStart. A refusal completes the channel call with
// error code "vpn_start_refused" + the exception's simple name,
// which the Dart side already surfaces as lastError/snackbar.
// Plus log hygiene: psiphon.log rotates at EVERY session start
// (it used to append across sessions, so the owner read a stale
// 2065 flood as 2066's current failure), and tunlink.log rotates
// per session in the Xray and Lantern services the same way.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/psiphon/psiphon_controller.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

/// The source segment of one `when` branch in the method-call
/// handler: from its method literal to the next branch marker.
String branchOf(String source, String method, String nextMarker) {
  final start = source.indexOf('"$method" ->');
  expect(start, isNonNegative, reason: 'branch "$method" exists');
  final end = source.indexOf(nextMarker, start);
  expect(end, isNonNegative, reason: 'branch "$method" is bounded');
  return source.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mainActivity = ktSrc('MainActivity.kt');

  group('2066 defect (confirmed): the VPN start handoff ran '
      'unguarded — a native throw at the tap killed the process',
      () {
    test('the handler carries the guard and the refusal code', () {
      expect(mainActivity.contains('fun startVpnGuarded('), isTrue);
      expect(mainActivity.contains('fun runDeferredVpnStart('), isTrue);
      expect(mainActivity.contains('"vpn_start_refused"'), isTrue);
      // The exception's simple name rides in the error message,
      // so the surfaced lastError names the refusal.
      expect(
        mainActivity.contains(r'"${e.javaClass.simpleName}: ${e.message}"'),
        isTrue,
      );
    });

    test('the Psiphon start branch routes through the guard and '
        'never calls prepare() itself', () {
      final branch =
          branchOf(mainActivity, 'psiphonSetOn', '"psiphonStop"');
      expect(branch.contains('startVpnGuarded('), isTrue);
      expect(branch.contains('needsConsent = vpnMode'), isTrue);
      expect(branch.contains('VpnService.prepare'), isFalse);
      expect(branch.contains('startActivityForResult'), isFalse);
    });

    test('the Xray and Lantern start branches route through the '
        'guard too', () {
      final xray = branchOf(mainActivity, 'xraySetOn', '"xrayStop"');
      expect(xray.contains('startVpnGuarded('), isTrue);
      expect(xray.contains('VpnService.prepare'), isFalse);
      final lantern =
          branchOf(mainActivity, 'lanternSetOn', '"lanternStop"');
      expect(lantern.contains('startVpnGuarded('), isTrue);
      expect(lantern.contains('VpnService.prepare'), isFalse);
    });

    test('every other consent-pattern start branch is guarded '
        'the same way', () {
      for (final (method, next) in [
        ('awgSetOn', '"xrayRotateConfig"'),
        ('xraySetOnWarp', '"warpStart"'),
        ('socksTunSetOn', '"xrayEndurance"'),
        ('openVpnSetOn', '"openVpnStop"'),
      ]) {
        final branch = branchOf(mainActivity, method, next);
        expect(
          branch.contains('startVpnGuarded('),
          isTrue,
          reason: '$method routes through startVpnGuarded',
        );
        expect(
          branch.contains('VpnService.prepare'),
          isFalse,
          reason: '$method no longer calls prepare() directly',
        );
      }
      // UPDATED by build 2070 (review §9 item 1): the Mozilla
      // branch no longer spells out its own guard — since
      // CoreService.turnOn records-and-rethrows instead of
      // completing the result itself, the branch routes through
      // startVpnGuarded like every other engine, so it carries
      // the guard call (and, through it, the refusal code)
      // rather than the literal.
      final mozilla = branchOf(mainActivity, 'setOn', '"isRunning"');
      expect(mozilla.contains('startVpnGuarded('), isTrue);
      expect(mozilla.contains('VpnService.prepare'), isFalse);
      expect(mozilla.contains('startActivityForResult'), isFalse);
    });

    test('prepare() survives only inside the guard and the '
        'settings check', () {
      final sites = 'VpnService.prepare(this)'
          .allMatches(mainActivity)
          .length;
      // 1: startVpnGuarded itself. 2: the "setConnectionMode"
      // settings check, which is not a start path and answers
      // vpn_denied. (Build 2070: the Mozilla branch's inline
      // prepare() is gone — it routes through the guard now,
      // so the count drops from 3 to 2.)
      expect(sites, 2);
      // The consent launch likewise survives only in the guard.
      // (Build 2070: was 2 with the Mozilla branch's inline
      // launch; the branch parks through the guard now.)
      final launches = 'startActivityForResult(consent, VPN_REQUEST)'
          .allMatches(mainActivity)
          .length;
      expect(launches, 1);
    });

    test('onActivityResult runs every deferred start through '
        'the guard', () {
      final count = 'runDeferredVpnStart(pending, start)'
          .allMatches(mainActivity)
          .length;
      // OpenVPN, Psiphon, WARP, AWG, Xray, Lantern.
      expect(count, 6);
      // The only start?.invoke() left in the file is the one
      // inside runDeferredVpnStart itself.
      expect('start?.invoke()'.allMatches(mainActivity).length, 1);
    });
  });

  group('log hygiene: a stale flood must never masquerade as a '
      'current failure', () {
    test('psiphon.log rotates at every session start', () {
      final service = ktSrc('PsiphonVpnService.kt');
      final openLogAt = service.indexOf('private fun openLog');
      expect(openLogAt, isNonNegative);
      final openLog = service.substring(openLogAt, openLogAt + 1800);
      expect(openLog.contains('Build 2067'), isTrue);
      expect(openLog.contains('"psiphon.log.old"'), isTrue);
      expect(openLog.contains('f.renameTo(old)'), isTrue);
      // The size condition that made rotation rare is gone.
      expect(openLog.contains('512 * 1024'), isFalse);
      // The writer still starts fresh afterwards (append onto a
      // file that was just rotated away = a new file).
      expect(openLog.contains('FileOutputStream(f, true)'), isTrue);
      // The 2066 dedupe stays.
      expect(service.contains('the previous line repeated'), isTrue);
    });

    test('tunlink.log rotates per session in Xray and Lantern',
        () {
      final xray = ktSrc('XrayVpnService.kt');
      expect('rotateLogPerSession(tunLog)'.allMatches(xray).length, 3);
      expect(xray.contains('fun rotateLogPerSession('), isTrue);
      // xray.log keeps its size-based rule (not a session log
      // the owner reads for bridge floods).
      expect(xray.contains('rotateLogIfLarge(xrayLog)'), isTrue);
      final lantern = ktSrc('LanternVpnService.kt');
      expect('rotateLogPerSession(tunLog)'.allMatches(lantern).length, 1);
      expect(lantern.contains('fun rotateLogPerSession('), isTrue);
    });
  });

  group('Dart behaviour: a native start refusal surfaces as '
      'lastError, never as a crash', () {
    late PsiphonController controller;

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app/android'),
        (call) async {
          switch (call.method) {
            case 'psiphonState':
              return <String, Object?>{
                'running': false,
                'connected': false,
                'vpnMode': true,
                'sinceMs': 0,
                'up': 0,
                'down': 0,
                'region': '',
                'clientAddress': '',
                'regions': <String>[],
                'method': '',
              };
            case 'psiphonSetOn':
              // The 2067 native guard's answer to a refused
              // start (e.g. HyperOS foreground-service refusal on
              // a fresh install).
              throw PlatformException(
                code: 'vpn_start_refused',
                message: 'ForegroundServiceStartNotAllowedException: '
                    'mock refusal',
              );
            default:
              return null;
          }
        },
      );
      controller = PsiphonController();
      // Keep connect() off the network: fresh edge results mean
      // the pre-connect probe refresh is skipped.
      controller.settings.edgesTestedAtMs =
          DateTime.now().millisecondsSinceEpoch;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app/android'),
        null,
      );
      controller.dispose();
    });

    test('connect() throws the refusal as a PlatformException and '
        'records it in lastError', () async {
      await expectLater(
        controller.connect(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'vpn_start_refused')
              .having(
                (e) => e.message,
                'message',
                contains('ForegroundServiceStartNotAllowedException'),
              ),
        ),
      );
      expect(controller.lastError, contains('vpn_start_refused'));
      expect(
        controller.lastError,
        contains('ForegroundServiceStartNotAllowedException'),
      );
      expect(controller.connecting, isFalse);
    });
  });
}
