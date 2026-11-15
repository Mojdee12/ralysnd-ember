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
      expect(occurrences(manifest, 'android:process'), 1,
          reason: 'no other component gained a process attribute');
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

    test('every state setter republishes (10 setters + the definition)',
        () {
      expect(occurrences(service, 'publishState()'), 11,
          reason: 'running, connected, isVpnMode, startedAtMs, '
              'totalUp, totalDown, egressRegion, clientAddress, '
              'availableRegions, activeMethod — each setter calls '
              'publishState(), plus its one definition');
    });

    test('the snapshot carries all ten fields under the channel keys', () {
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
