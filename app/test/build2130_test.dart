// Build 2130 — the Lantern classloader singleton hotfix.
//
// Build 2129 cached the plugin DexClassLoader per
// LanternBridge instance. The :lantern process outlives
// service instances (the info / smart / private actions
// stopSelf() when no session runs), so a second bridge built
// a SECOND DexClassLoader over the same dexes — and Android
// allows a native library to be loaded by only ONE
// classloader per process. go.Seq's loadLibrary then threw
// UnsatisfiedLinkError ("already opened by ClassLoader…")
// for every later Lantern operation in that process: on the
// owner's device Lantern was completely dead (his 2026-11-22
// crash export: startTunnel + addPrivate, build 2129).
//
// The fix: the loader is a process-wide singleton in the
// bridge's companion object (@Volatile + @Synchronized
// lazy-once). The ENGINE stays per-bridge on purpose —
// LanternEngine captures its VpnService and builds the TUN
// through it in openTun (this.service.new Builder()), so a
// shared engine would build TUNs through a destroyed
// service; loaded through the one loader, the engine class
// (and go.Seq) initializes exactly once per process.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

void main() {
  final kt = ktSrc('LanternVpnService.kt');
  final bridgeJava = File(
    'android/lantern-plugin-src/com/ralysnd/ember/lanternplugin/LanternEngine.java',
  ).readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();

  final companionAt = kt.indexOf('private companion object');
  final invokeAt = kt.indexOf('private fun invoke(');
  final companion =
      (companionAt >= 0 && invokeAt > companionAt)
          ? kt.substring(companionAt, invokeAt)
          : '';
  final bridgeAt = kt.indexOf('private class LanternBridge');
  final instanceRegion =
      (bridgeAt >= 0 && companionAt > bridgeAt)
          ? kt.substring(bridgeAt, companionAt)
          : '';

  group('the loader is a process-wide singleton', () {
    test('held in the companion object, volatile + synchronized', () {
      expect(companionAt, greaterThanOrEqualTo(0),
          reason: 'LanternBridge must hold the loader in a companion object');
      expect(companion, contains('@Volatile'));
      expect(companion, contains('private var sharedLoader: ClassLoader? = null'));
      expect(companion, contains('@Synchronized'));
      expect(companion, contains('fun sharedClassLoader('));
    });

    test('lazy-once: an existing loader is returned, never rebuilt', () {
      expect(companion, contains('sharedLoader?.let { return it }'));
      expect(companion, contains('sharedLoader = created'));
    });

    test('exactly one ChildLoader construction in the file, '
        'inside the singleton', () {
      // One construction + the class declaration itself.
      expect('ChildLoader('.allMatches(kt).length, 2);
      expect('ChildLoader('.allMatches(companion).length, 1);
      expect('ChildLoader('.allMatches(instanceRegion).length, 0);
    });

    test('no per-instance loader field remains', () {
      expect(kt.contains('private var loader'), isFalse);
      expect(instanceRegion.contains('ClassLoader? = null'), isFalse);
    });

    test('the bridge delegates to the singleton', () {
      expect(
        kt,
        contains(
          'private fun classLoader(): ClassLoader = '
          'sharedClassLoader(service)',
        ),
      );
    });

    test('dex install moved with the singleton, byte-identical '
        'copies still kept', () {
      expect(
        companion,
        contains(
          'private fun installDex(service: VpnService, '
          'asset: String, target: File)',
        ),
      );
      expect(companion, contains('contentEquals(bytes)'));
      expect(companion, contains('"lantern-plugin.dex"'));
      expect(companion, contains('"lantern-bridge.dex"'));
    });
  });

  group('the engine stays per-bridge (deliberate)', () {
    test('engine is still an instance field, built from the '
        'bridge\'s own live service', () {
      expect(instanceRegion, contains('private var engine: Any? = null'));
      expect(kt, contains('newInstance(service)'));
      expect(kt, contains('cls.getConstructor(VpnService::class.java)'));
    });

    test('why: LanternEngine builds the TUN through its '
        'captured service at connect time', () {
      expect(bridgeJava, contains('private final VpnService service;'));
      expect(bridgeJava, contains('this.service.new Builder()'));
      expect(bridgeJava, contains('this.service.protect(fd)'));
    });
  });

  test('pubspec is build 2130', () {
    expect(pubspec, contains('version: 2.2.0+2155'));
  });
}
