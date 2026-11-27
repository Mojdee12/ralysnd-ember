// Build 2073 — the Psiphon own-process fix.
//
// The stop-line investigation (psiphon-stop-line-investigation.md)
// proved the owner's Psiphon start dies inside Psi.stop() — the
// wrapper's pre-start cleanup, the FIRST call into the Psiphon Go
// library; Psi.start() is never reached. In Ember's main process
// the pg gomobile runtime is the SECOND Go runtime resident: the
// Mozilla core (libgojni.so, package go) is loaded and started at
// every app launch. In ralysnd, where the byte-identical stack
// works, the pg runtime is the first and only gomobile runtime in
// its process. This build restores that condition by running
// PsiphonVpnService in its own process (:psiphon), in any engine
// order, with Mozilla untouched.
//
// The only same-process coupling the move breaks is STATE: the
// main process read the service's companion statics directly
// (MainActivity's psiphonState channel; XrayVpnService's chain
// checks). Since this build the service publishes a JSON snapshot
// of all ten state fields to workDir/psiphon_state.json on every
// mutation (the setters publish), and the main process reads that
// file. Start/stop were already intent-based; logs and crash.log
// were already files; nothing else about the engine changes.
//
// EmberApplication also gains ONE process-birth breadcrumb per
// process start, naming the process — the decider the
// investigation named for abort-vs-deadlock inside Psi.stop().
// Whether Psi.stop() returns in the isolated process is decidable
// only on the owner's phone; these pins prove the wiring.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String manifestSrc() =>
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

int occurrences(String haystack, String needle) =>
    haystack.split(needle).length - 1;

void main() {
  group('manifest: Psiphon isolation', () {
    test('PsiphonVpnService carries :psiphon and nothing else does', () {
      final manifest = manifestSrc();
      final nameAt = manifest.indexOf('android:name=".PsiphonVpnService"');
      expect(nameAt, greaterThan(0), reason: 'the service is declared');
      // The service element's own attributes sit within a few
      // hundred characters after its name (exported, FGS type,
      // permission) — the process attribute must be among them.
      final element = manifest.substring(nameAt, nameAt + 700);
      expect(element.contains('android:process=":psiphon"'), isTrue,
          reason: 'the Psiphon service runs in its own process');
      // Build 2100 (W-WG2, named reason): AwgVpnService joined
      // with android:process=":awg" — the count is now two, and
      // the standing packaging gate expects exactly
      // {:psiphon, :awg}. This pin follows the manifest; the
      // "nothing else" rule still holds for every other
      // component.
      // Build 2104: :awg is deleted with the engine swap (the
      // WG Tunnel backend runs in the main process) — the set
      // is {:psiphon} alone again, and the packaging gate's
      // named expectation follows.
      // Build 2129: LanternVpnService joins with
      // android:process=":lantern" (the gomobile core runs in
      // its own process, mirroring :psiphon) — the set is
      // {:psiphon, :lantern}.
      // Build 2156 re-point: UrVpnService joins with
      // android:process=":urnetwork" (its gomobile core's
      // own process, same reasoning) — the set is
      // {:psiphon, :lantern, :urnetwork}.
      expect(occurrences(manifest, 'android:process'), 3,
          reason: ':psiphon, :lantern and :urnetwork carry '
              'process attributes');
    });
  });

  group('published state (the cross-process state channel)', () {
    final service = ktSrc('PsiphonVpnService.kt');

    test('the snapshot file, publisher and readers exist', () {
      expect(service.contains('STATE_FILE = "psiphon_state.json"'), isTrue);
      expect(service.contains('private fun publishState()'), isTrue);
      expect(service.contains('AtomicFile.writeText('), isTrue,
          reason: 'the snapshot lands atomically, never torn');
      expect(service.contains('fun publishedState('), isTrue);
      expect(service.contains('fun publishedRunning('), isTrue);
      expect(service.contains('fun publishedConnected('), isTrue);
      expect(service.contains('fun bindAppContext('), isTrue);
      expect(service.contains('bindAppContext(this)'), isTrue,
          reason: 'onCreate captures the publishing context');
    });

    // Build 2087: the count grows 10 -> 11 setters — the wedge
    // flag (hang diagnosis F1) is a published state field like
    // the others, with its own republishing setter.
    // Build 2088: 11 -> 12 — startReturned (the external
    // watchdog's discriminator) joins it the same way.
    // Build 2116 (B10-1): 13 -> 14 call sites — the periodic
    // republish loop republishes the unchanged snapshot every
    // 30 s while running, which is what makes the reader-side
    // staleness bound meaningful. Deliberate re-point; the 12
    // setters + the definition are unchanged.
    test('every state setter republishes (12 setters + the definition)',
        () {
      // Build 2125 re-point (A25-04): 14 -> 15 call sites —
      // killSwitchHeld (the Psiphon kill-switch hold) joins
      // the published set, and its setter republishes like
      // every other.
      expect(occurrences(service, 'publishState()'), 15,
          reason: 'running, connected, isVpnMode, startedAtMs, '
              'totalUp, totalDown, egressRegion, clientAddress, '
              'availableRegions, activeMethod, wedged, '
              'startReturned, killSwitchHeld — each setter '
              'calls publishState(), plus its definition, plus '
              'the 2116 republish loop');
    });

    test('the snapshot carries all twelve fields under the channel keys',
        () {
      for (final key in [
        'running',
        'connected',
        'vpnMode',
        'sinceMs',
        'up',
        'down',
        'region',
        'clientAddress',
        'regions',
        'method',
        'wedged',
        'startReturned',
      ]) {
        expect(service.contains('"$key"'), isTrue, reason: 'key $key');
      }
    });
  });

  group('main process reads the snapshot, never the statics', () {
    const stateFields = [
      'running',
      'connected',
      'isVpnMode',
      'startedAtMs',
      'totalUp',
      'totalDown',
      'egressRegion',
      'clientAddress',
      'availableRegions',
      'activeMethod',
      'wedged',
    ];

    test('MainActivity answers psiphonState from the snapshot', () {
      final main = ktSrc('MainActivity.kt');
      expect(main.contains('PsiphonVpnService.publishedState(this)'), isTrue);
      for (final field in stateFields) {
        expect(main.contains('PsiphonVpnService.$field'), isFalse,
            reason: 'MainActivity must not read the :psiphon static $field');
      }
    });

    test('XrayVpnService chain checks read the snapshot', () {
      final xray = ktSrc('XrayVpnService.kt');
      expect(xray.contains('PsiphonVpnService.publishedRunning('), isTrue);
      expect(xray.contains('PsiphonVpnService.publishedConnected('), isTrue);
      expect(xray.contains('PsiphonVpnService.running'), isFalse);
      expect(xray.contains('PsiphonVpnService.connected'), isFalse);
    });
  });

  group('process-birth breadcrumb', () {
    test('EmberApplication records one birth line naming the process', () {
      final app = ktSrc('EmberApplication.kt');
      expect(app.contains('CrashLog.breadcrumb(this, "process-birth '), isTrue);
      expect(app.contains('currentProcessName()'), isTrue);
      expect(app.contains('getProcessName()'), isTrue,
          reason: 'API 28+ process name');
      expect(app.contains('runningAppProcesses'), isTrue,
          reason: 'pre-28 fallback via ActivityManager');
    });
  });
}
