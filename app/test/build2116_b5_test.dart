// Build 2116, batch B5 (Aether) — proving tests.
//
// B5-1: the native MASQUE ladder now proves data FIRST and
// treats the trace as advisory (an answered warp=off stays
// fatal; a silent trace leaves the rung standing with its
// exit unverified) — the verdict reaches Dart and stamps
// the session. B5-2: the ECH option the Kotlin side always
// accepted is carried end to end. B5-3: identity validity
// demands the complete MASQUE pair and a refusal surfaces
// by name. B5-7: the exit-unverified stamp persists.
// B5-8/B5-9 (device-proven on build 2115): the engine's
// fresh end-to-end validation outranks a cold re-probe,
// and the probe's read budget scales to the measured RTT.
// Kotlin has no unit harness in this tree — its rows are
// pinned at the source, the established pattern here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/aether/aether_controller.dart';
import 'package:firefox_vpn/aether/aether_platform.dart';

String _kotlin() => File(
  'android/app/src/main/kotlin/com/ralysnd/ember/AetherCore.kt',
).readAsStringSync();

void _mockAndroidChannel(
  Map<String, Object? Function(MethodCall)> handlers,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app/android'), (
        call,
      ) async {
        final h = handlers[call.method];
        if (h != null) return h(call);
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app/android'), null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B5-2 ECH option', () {
    test('defaults empty and rides toMap/toJson both ways', () {
      const o = AetherOptions();
      expect(o.ech, '');
      expect(o.toMap('aether-ralysnd')['ech'], '');
      final custom = o.copyWith(ech: 'config-bytes');
      expect(custom.toMap('aether-ralysnd')['ech'], 'config-bytes');
      final back = AetherOptions.fromJson(custom.toJson());
      expect(back.ech, 'config-bytes');
      // A store written before 2116 has no ech key at all.
      expect(AetherOptions.fromJson(const {'protocol': 'wg'}).ech, '');
    });
  });

  group('B5 state fields', () {
    test('engineValidated and identityRefused parse from the map', () {
      final s = AetherState.fromMap(const {
        'running': true,
        'engineValidated': true,
        'identityRefused': true,
      });
      expect(s.engineValidated, isTrue);
      expect(s.identityRefused, isTrue);
      final plain = AetherState.fromMap(const {'running': true});
      expect(plain.engineValidated, isFalse);
      expect(plain.identityRefused, isFalse);
    });
  });

  group('B5-7 exit stamp persistence', () {
    test('a stored stamp loads back; saves carry the key', () async {
      final tmp = await Directory.systemTemp.createTemp('ember2116b5');
      addTearDown(() => tmp.delete(recursive: true));
      // The options file lives in the PARENT of the core
      // data dir (AetherController._optionsFile).
      final coreDir = await Directory('${tmp.path}/core').create();
      _mockAndroidChannel({
        'dataDir': (_) => coreDir.path,
        'aetherState': (_) => {'running': false},
        'xrayState': (_) => {'running': false},
      });
      final storeFile = File('${tmp.path}/aether_cfwarp_options.json');
      await storeFile.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'protocol': 'wg',
          'scan': 'turbo',
          'exitUnverified': true,
        }),
      );
      final c = AetherController('cfwarp');
      addTearDown(c.dispose);
      await c.load();
      expect(c.exitUnverified, isTrue);
      await c.setOptions(c.options.copyWith(scan: 'balanced'));
      final doc =
          jsonDecode(await storeFile.readAsString()) as Map<String, dynamic>;
      expect(doc['exitUnverified'], isTrue);
      expect(doc['scan'], 'balanced');
    });
  });

  group('B5 Kotlin pins', () {
    test('B5-1: bringUp proves data before the trace verdict', () {
      final src = _kotlin();
      final bringUp = src.substring(
        src.indexOf('private fun bringUp('),
        src.indexOf('private enum class WarpProof'),
      );
      final dataAt = bringUp.indexOf('dataProbe()');
      final traceAt = bringUp.indexOf('warpProofOutcome()');
      expect(dataAt, greaterThan(0));
      expect(traceAt, greaterThan(dataAt));
      // The three honest outcomes exist and OFF stays fatal.
      expect(src, contains('WarpProof.OFF'));
      expect(src, contains('the exit answered, but not through WARP'));
      // The verdict reaches the platform caller.
      expect(src, contains('"exitUnverified" to outcome.exitUnverified'));
    });

    test('B5-8: the engine validation is recorded and outranks '
        'a cold re-probe', () {
      final src = _kotlin();
      expect(src, contains('wireguard tunnel validated'));
      expect(src, contains('engineValidatedAtMs'));
      expect(src, contains('fun engineValidationFresh()'));
      // dataProbe routes its failures through the verdict.
      final probe = src.substring(
        src.indexOf('fun dataProbe()'),
        src.indexOf('private fun probeRequest('),
      );
      expect(probe, contains('fun verdict('));
      expect(probe, contains('engineValidationFresh()'));
      expect(probe, contains('engine-validated (re-check said:'));
    });

    test('B5-9: the probe budget scales with the measured RTT', () {
      final src = _kotlin();
      expect(src, contains('fun probeIoTimeoutMs()'));
      expect(src, contains('ioTimeoutMs = probeIoTimeoutMs()'));
      expect(src, contains('lastRttMs'));
    });

    test('B5-3: identity validity demands the complete pair', () {
      final src = _kotlin();
      final valid = src.substring(
        src.indexOf('private fun identityValid('),
        src.indexOf('fun resetIdentity(context: Context)'),
      );
      expect(valid, contains('-----END CERTIFICATE-----'));
      expect(valid, contains('key_pem'));
      expect(src, contains('fun isIdentityRefusal('));
      expect(src, contains('"identityRefused" to identityRefused'));
    });

    test('B5-1 Dart: the ladder verdict stamps the session', () {
      final src = File('lib/aether/aether_controller.dart').readAsStringSync();
      expect(src, contains("exitUnverified = verdict['exitUnverified'] == true"));
      expect(src, contains('_saveStamp()'));
    });
  });
}
