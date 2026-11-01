import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/app_settings.dart';
import 'package:firefox_vpn/core/core_process.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('app_settings_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('defaults without a file', () async {
    final s = await AppSettings.load(dir.path);
    // Ralysnd Ember ships English as the default language (2006).
    expect(s.language, 'en');
    expect(s.locale, const Locale('en'));
    // Ralysnd Ember is a dark-first design: dark is the shipped default.
    expect(s.themeMode, ThemeMode.dark);
    expect(s.closeAction, CloseAction.ask);
    expect(s.firstRun, isTrue);
    // Starting with Windows is on until the user turns it off.
    expect(s.autostart, isTrue);
    // Connecting by itself is the user's choice.
    expect(s.autoConnect, isFalse);
  });

  test('saves and loads the choices', () async {
    final s = await AppSettings.load(dir.path);
    s.update(
      language: 'fa',
      themeMode: ThemeMode.dark,
      closeAction: CloseAction.tray,
      firstRun: false,
      autostart: false,
      autoConnect: true,
    );
    // update saves in the background.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final again = await AppSettings.load(dir.path);
    expect(again.locale, const Locale('fa'));
    expect(again.themeMode, ThemeMode.dark);
    expect(again.closeAction, CloseAction.tray);
    expect(again.firstRun, isFalse);
    expect(again.autostart, isFalse);
    expect(again.autoConnect, isTrue);
  });

  test('2006 migration resets the old Persian default to English once',
      () async {
    // A pre-2006 settings file: language fa was the shipped default.
    File('${dir.path}/app-settings.json')
        .writeAsStringSync('{"language": "fa", "welcome_done": true}');
    final s = await AppSettings.load(dir.path);
    expect(s.language, 'en');
    expect(s.emberEnDefaultApplied, isTrue);
    // The migration persisted itself, and a later deliberate pick of
    // Persian (flag present) is respected.
    File('${dir.path}/app-settings.json').writeAsStringSync(
        '{"language": "fa", "welcome_done": true, "ember_en_default": true}');
    final again = await AppSettings.load(dir.path);
    expect(again.language, 'fa');
  });

  test('maps languages to routing regions', () {
    expect(AppSettings.regionForLanguage('fa'), 'ir');
    expect(AppSettings.regionForLanguage('zh'), 'cn');
    expect(AppSettings.regionForLanguage('ru'), 'ru');
    expect(AppSettings.regionForLanguage('en'), isNull);
    expect(AppSettings.suggestedRegion('en', 'TR'), 'tr');
    expect(AppSettings.suggestedRegion('en', 'US'), '');
    expect(AppSettings.suggestedRegion('fa', 'DE'), 'ir');
  });

  test('ignores unknown values', () async {
    File('${dir.path}/app-settings.json')
        .writeAsStringSync('{"language": "xx", "theme": "neon", "close": 7}');
    final s = await AppSettings.load(dir.path);
    expect(s.language, 'en');
    expect(s.themeMode, ThemeMode.system);
    expect(s.closeAction, CloseAction.ask);
  });

  test('takes the core executable from --core', () {
    expect(
      CoreProcess.executableFrom(['--core=C:/bin/core.exe']),
      'C:/bin/core.exe',
    );
    expect(
      CoreProcess.executableFrom(const []),
      endsWith(
        Platform.isWindows
            ? r'core\firefox-vpn-core.exe'
            : 'core/firefox-vpn-core',
      ),
    );
  });
}
