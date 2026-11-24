/// Build 2077 — feature queue #7, biometric half: fingerprint /
/// face unlock for the app lock, on the framework BiometricPrompt
/// (no new dependency — no local_auth in the pub cache, no
/// androidx.biometric in the Gradle cache). The PIN always stays
/// the fallback: a biometric failure, cancel or lockout only
/// falls back to the keypad.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/android_core.dart';
import 'package:firefox_vpn/ui/ember/app_lock.dart';
import 'package:firefox_vpn/ui/ember/ember_theme.dart';

String _read(String path) => File(path).readAsStringSync();

String _kt(String name) =>
    _read('android/app/src/main/kotlin/com/ralysnd/ember/$name');

/// A scripted biometric platform: [available] answers the
/// enrolment question; [answers] are consumed in order by
/// each authenticate call (false = cancel/mismatch).
class _FakeBio {
  _FakeBio({required this.available, List<bool>? answers})
    : answers = List.of(answers ?? const <bool>[]);

  final bool available;
  final List<bool> answers;
  int availableCalls = 0;
  int authenticateCalls = 0;

  Future<bool> check() async {
    availableCalls++;
    return available;
  }

  Future<bool> prompt() async {
    authenticateCalls++;
    return answers.isNotEmpty ? answers.removeAt(0) : false;
  }
}

AppSettings _lockedSettings() {
  final s = AppSettings();
  s.update(appLockPinHash: pinHashOf('1234'));
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('appLockBiometric setting', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('bio2077_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<Map<String, dynamic>> savedDoc(AppSettings s) async {
      final file = File('${dir.path}/app-settings.json');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        try {
          final doc =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          if (doc.containsKey('app_lock_biometric')) return doc;
        } catch (_) {
          // Not written yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      fail('app-settings.json never landed');
    }

    test('defaults to off', () async {
      final s = await AppSettings.load(dir.path);
      expect(s.appLockBiometric, isFalse);
    });

    test('persists across a reload', () async {
      final s = await AppSettings.load(dir.path);
      s.update(appLockPinHash: pinHashOf('1234'), appLockBiometric: true);
      final doc = await savedDoc(s);
      expect(doc['app_lock_biometric'], isTrue);
      final reloaded = await AppSettings.load(dir.path);
      expect(reloaded.appLockBiometric, isTrue);
      expect(reloaded.appLockEnabled, isTrue);
    });

    test('a legacy store without the key reads off', () async {
      final file = File('${dir.path}/app-settings.json');
      await file.writeAsString(
        jsonEncode({'app_lock_pin_hash': pinHashOf('1234')}),
      );
      final s = await AppSettings.load(dir.path);
      expect(s.appLockBiometric, isFalse);
    });

    test('a wrong-typed stored value reads off', () async {
      final file = File('${dir.path}/app-settings.json');
      await file.writeAsString(
        jsonEncode({
          'app_lock_pin_hash': pinHashOf('1234'),
          'app_lock_biometric': 'yes',
        }),
      );
      final s = await AppSettings.load(dir.path);
      expect(s.appLockBiometric, isFalse);
    });

    test('cannot be turned on without a PIN', () {
      final s = AppSettings();
      s.update(appLockBiometric: true);
      expect(s.appLockBiometric, isFalse);
    });

    test('clearing the PIN clears biometrics in the same update', () {
      final s = _lockedSettings();
      s.update(appLockBiometric: true);
      expect(s.appLockBiometric, isTrue);
      s.update(appLockPinHash: '');
      expect(s.appLockEnabled, isFalse);
      expect(s.appLockBiometric, isFalse);
    });

    test('turning biometrics off keeps the PIN', () {
      final s = _lockedSettings();
      s.update(appLockBiometric: true);
      s.update(appLockBiometric: false);
      expect(s.appLockBiometric, isFalse);
      expect(s.appLockEnabled, isTrue);
      expect(pinMatches(s, '1234'), isTrue);
    });
  });

  group('AndroidCore biometrics channel', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app/android'), null);
    });

    void mockChannel(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app/android'),
            handler,
          );
    }

    test('passes the platform answers through', () async {
      mockChannel((call) async {
        return switch (call.method) {
          'biometricsAvailable' => true,
          'biometricAuthenticate' => true,
          _ => null,
        };
      });
      expect(await AndroidCore.biometricsAvailable(), isTrue);
      expect(await AndroidCore.authenticateBiometric(), isTrue);
    });

    test('false and null answers read false', () async {
      mockChannel((call) async {
        return switch (call.method) {
          'biometricsAvailable' => false,
          'biometricAuthenticate' => null,
          _ => null,
        };
      });
      expect(await AndroidCore.biometricsAvailable(), isFalse);
      expect(await AndroidCore.authenticateBiometric(), isFalse);
    });

    test('a missing platform call reads false, never throws', () async {
      // No mock handler: the channel throws
      // MissingPluginException, which both methods swallow.
      expect(await AndroidCore.biometricsAvailable(), isFalse);
      expect(await AndroidCore.authenticateBiometric(), isFalse);
    });
  });

  group('AppLockPage biometrics', () {
    testWidgets('no pill when biometrics are off', (tester) async {
      final bio = _FakeBio(available: true, answers: [true]);
      var unlocked = false;
      final s = _lockedSettings();
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(
            settings: s,
            onUnlocked: () => unlocked = true,
            biometricAvailable: bio.check,
            biometricAuthenticate: bio.prompt,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Use fingerprint or face'), findsNothing);
      expect(bio.availableCalls, 0);
      expect(bio.authenticateCalls, 0);
      expect(unlocked, isFalse);
    });

    testWidgets('no pill when the device has nothing enrolled', (tester) async {
      final bio = _FakeBio(available: false);
      var unlocked = false;
      final s = _lockedSettings()..update(appLockBiometric: true);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(
            settings: s,
            onUnlocked: () => unlocked = true,
            biometricAvailable: bio.check,
            biometricAuthenticate: bio.prompt,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Use fingerprint or face'), findsNothing);
      expect(bio.authenticateCalls, 0);
      expect(unlocked, isFalse);
    });

    testWidgets('a failed auto-prompt leaves the PIN pad, once', (
      tester,
    ) async {
      final bio = _FakeBio(available: true, answers: [false, true]);
      var unlocked = false;
      final s = _lockedSettings()..update(appLockBiometric: true);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(
            settings: s,
            onUnlocked: () => unlocked = true,
            biometricAvailable: bio.check,
            biometricAuthenticate: bio.prompt,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The auto-prompt fired once and failed; the pill is
      // there with the fallback caption, the pad still works.
      expect(bio.authenticateCalls, 1);
      expect(find.text('Use fingerprint or face'), findsOneWidget);
      expect(
        find.text('Biometric didn\'t match — enter your PIN'),
        findsOneWidget,
      );
      expect(unlocked, isFalse);
      // A manual tap prompts again and unlocks.
      // Build 2137 (visual review V-27): the pad sits on a
      // MapGlass panel now and the page's column is taller
      // — at the default test surface the pill starts
      // below the fold of its scroll view, so bring it
      // into view first (the pinned behaviour is unchanged).
      await tester.ensureVisible(find.text('Use fingerprint or face'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use fingerprint or face'));
      await tester.pumpAndSettle();
      expect(bio.authenticateCalls, 2);
      expect(unlocked, isTrue);
    });

    testWidgets('a matching auto-prompt unlocks at once', (tester) async {
      final bio = _FakeBio(available: true, answers: [true]);
      var unlocked = false;
      final s = _lockedSettings()..update(appLockBiometric: true);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(
            settings: s,
            onUnlocked: () => unlocked = true,
            biometricAvailable: bio.check,
            biometricAuthenticate: bio.prompt,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(bio.authenticateCalls, 1);
      expect(unlocked, isTrue);
    });

    testWidgets('the PIN still unlocks after a failed biometric', (
      tester,
    ) async {
      final bio = _FakeBio(available: true, answers: [false]);
      var unlocked = false;
      final s = _lockedSettings()..update(appLockBiometric: true);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockPage(
            settings: s,
            onUnlocked: () => unlocked = true,
            biometricAvailable: bio.check,
            biometricAuthenticate: bio.prompt,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(unlocked, isFalse);
      for (final digit in ['1', '2', '3', '4']) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      expect(unlocked, isTrue);
    });
  });

  group('AppLockSettingsPage biometrics', () {
    Future<void> pumpSettingsPage(
      WidgetTester tester,
      AppSettings s,
      _FakeBio bio,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockSettingsPage(settings: s, biometricAvailable: bio.check),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('toggle appears when a PIN is set and biometrics exist', (
      tester,
    ) async {
      final bio = _FakeBio(available: true);
      final s = _lockedSettings();
      await pumpSettingsPage(tester, s, bio);
      expect(find.text('Biometric unlock'), findsOneWidget);
      expect(find.byType(EmberToggle), findsOneWidget);
      await tester.tap(find.byType(EmberToggle));
      await tester.pumpAndSettle();
      expect(s.appLockBiometric, isTrue);
    });

    testWidgets('no toggle when nothing is enrolled — only the reason', (
      tester,
    ) async {
      final bio = _FakeBio(available: false);
      final s = _lockedSettings();
      await pumpSettingsPage(tester, s, bio);
      expect(find.text('Biometric unlock'), findsOneWidget);
      expect(find.byType(EmberToggle), findsNothing);
      expect(
        find.textContaining('aren\'t available on this device'),
        findsOneWidget,
      );
    });

    testWidgets('no biometric card without a PIN', (tester) async {
      final bio = _FakeBio(available: true);
      final s = AppSettings();
      await pumpSettingsPage(tester, s, bio);
      expect(find.text('Biometric unlock'), findsNothing);
      expect(find.byType(EmberToggle), findsNothing);
    });

    testWidgets('removing the PIN clears biometrics', (tester) async {
      final bio = _FakeBio(available: true);
      final s = _lockedSettings()..update(appLockBiometric: true);
      await pumpSettingsPage(tester, s, bio);
      expect(find.byType(EmberToggle), findsOneWidget);
      // The first text field is the current PIN.
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.tap(find.text('Remove PIN'));
      await tester.pumpAndSettle();
      expect(s.appLockEnabled, isFalse);
      expect(s.appLockBiometric, isFalse);
      expect(find.text('Biometric unlock'), findsNothing);
    });

    testWidgets('the old "no fingerprint unlock" copy is gone', (tester) async {
      final bio = _FakeBio(available: true);
      final s = _lockedSettings();
      await pumpSettingsPage(tester, s, bio);
      expect(find.textContaining('no fingerprint unlock'), findsNothing);
    });
  });

  group('Kotlin platform pins', () {
    late String mainActivity;
    late String manifest;
    late String androidCore;
    late String pubspec;

    setUp(() {
      mainActivity = _kt('MainActivity.kt');
      manifest = _read('android/app/src/main/AndroidManifest.xml');
      androidCore = _read('lib/core/android_core.dart');
      pubspec = _read('pubspec.yaml');
    });

    test('the two channel methods exist on both sides', () {
      expect(mainActivity, contains('"biometricsAvailable"'));
      expect(mainActivity, contains('"biometricAuthenticate"'));
      expect(androidCore, contains('biometricsAvailable()'));
      expect(androidCore, contains('authenticateBiometric()'));
      expect(androidCore, contains("'biometricsAvailable'"));
      expect(androidCore, contains("'biometricAuthenticate'"));
    });

    test('the prompt is the framework BiometricPrompt', () {
      expect(mainActivity, contains('BiometricPrompt.Builder'));
      expect(mainActivity, contains('setNegativeButton'));
      expect(mainActivity, contains('"Use PIN"'));
      expect(mainActivity, contains('onAuthenticationSucceeded'));
      expect(mainActivity, contains('onAuthenticationError'));
    });

    test('availability asks for a strong enrolled biometric', () {
      expect(mainActivity, contains('BIOMETRIC_STRONG'));
      expect(mainActivity, contains('canAuthenticate'));
      expect(mainActivity, contains('BIOMETRIC_SUCCESS'));
    });

    test('the API guards keep old phones on the PIN', () {
      expect(mainActivity, contains('SDK_INT < 29'));
      expect(mainActivity, contains('SDK_INT < 28'));
      expect(mainActivity, contains('SDK_INT >= 30'));
    });

    test('the result is answered exactly once', () {
      expect(mainActivity, contains('var answered = false'));
      // The first 'onAuthenticationFailed' in the file is the
      // doc comment on showBiometricPrompt — the override is
      // the one that matters, and its body ends at the
      // callback's closing '},'.
      final failedAt = mainActivity.indexOf(
        'override fun onAuthenticationFailed',
      );
      expect(failedAt, isNot(-1));
      final failedEnd = mainActivity.indexOf('},', failedAt);
      expect(failedEnd, isNot(-1));
      final failedBlock = mainActivity.substring(failedAt, failedEnd);
      expect(failedBlock, isNot(contains('answer(')));
      expect(failedBlock, contains('The prompt stays up for a retry'));
    });

    test('the manifest carries USE_BIOMETRIC', () {
      expect(manifest, contains('USE_BIOMETRIC'));
    });

    test('no new dependency was added for biometrics', () {
      expect(pubspec, isNot(contains('local_auth')));
      expect(mainActivity, isNot(contains('import androidx.biometric')));
    });
  });
}
