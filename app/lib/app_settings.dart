import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// What the window's close button does.
enum CloseAction { ask, tray, quit }

/// The app's own preferences (language, theme, close button), kept in
/// `app-settings.json` in the data folder beside the core's files. The VPN
/// settings belong to the core.
class AppSettings extends ChangeNotifier {
  AppSettings({this.file});

  final File? file;

  /// A language code (`en`, `fa`, `zh`, `ru`), or empty for the system
  /// language. Ralysnd Ember ships English as the first-run language
  /// (2006: the whole app is English by default); the user can pick
  /// another in Settings.
  String language = 'en';
  ThemeMode themeMode = ThemeMode.dark; // Ralysnd Ember is a dark-first design.
  CloseAction closeAction = CloseAction.ask;

  /// True until the user finished the welcome page.
  bool firstRun = false;

  /// Shows the public IP (the address websites see). Off by default: the
  /// location is shown by its country either way.
  bool showPublicIp = false;

  /// When the user closed the "account running out" notice; it stays away
  /// for a day after.
  DateTime? lowQuotaDismissedAt;

  /// The newer version whose notice the user closed; a later one shows.
  String dismissedUpdate = '';

  /// The last successful look for a newer version, and the newer version it
  /// found ("" for none) with its page, so the notice outlasts a restart.
  DateTime? updateCheckedAt;
  String updateVersion = '';
  String updateUrl = '';

  /// Downloads a newer version in the background and installs it the next
  /// time the app starts (the Windows app, which updates itself); on unless
  /// the user turned it off.
  bool autoUpdate = true;

  /// Starts the app in the tray when the user signs in to Windows; on
  /// unless the user turned it off.
  bool autostart = true;

  /// Connects by itself when started with the computer ([autostart]); off
  /// until the user turns it on. The core decides how (Daemon.AutoConnect).
  bool autoConnect = false;

  /// The home page's card when TUN mode refused a program's call or game
  /// (UDP); on unless the user turned it off.
  bool udpNotice = true;

  /// The columns the Logs page's Connections tab hides (ConnectionsView):
  /// at first all but the time, the destination, the rule, and the
  /// protocol. Kept in this file.
  Set<String> hiddenConnectionColumns = {'inbound', 'traffic', 'duration'};

  /// The engine the Ember panel shows: 0 = Mozilla, 1 = V2Ray.
  int emberMode = 0;

  /// Ember 2's baked-in defaults (VPN mode, smart routing off, DoH on)
  /// have been applied to the core once.
  bool ember2DefaultsApplied = false;

  /// The DESKTOP counterpart: the Windows first-run default (Mozilla
  /// capture mode "clear" → "tun" when the TUN service is installed)
  /// has been applied once. Separate from [ember2DefaultsApplied],
  /// which is Android's flag and path.
  bool desktopDefaultsApplied = false;

  /// The 2006 one-time migration has run: the stored language (which
  /// up to 2005 was the shipped Persian default, not necessarily a
  /// deliberate pick) was reset to English once. After this flag is
  /// set, the language picker owns the value again.
  bool emberEnDefaultApplied = false;

  /// The app's languages, in the order the language menus list them.
  /// 'zh' is Simplified and 'zh_Hant' Traditional Chinese.
  static const supportedLanguages = [
    'en',
    'fa',
    'zh',
    'zh_Hant',
    'ru',
    'tr',
    'ar',
    // The rest by their own names.
    'az',
    'id',
    'es',
    'fr',
    'hu',
    'pt',
    'vi',
    'bn',
  ];

  /// Languages written right to left.
  static const rtlLanguages = {'fa', 'ar'};

  /// The locale of a language code such as 'fa' or 'zh_Hant'.
  static Locale localeOf(String language) {
    final parts = language.split('_');
    return parts.length == 2
        ? Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1])
        : Locale(language);
  }

  /// The app language for the system's [locale]: Traditional Chinese for
  /// the Hant script or Taiwan, Hong Kong, and Macau; else the language
  /// when the app has it; else English.
  static String languageFor(Locale locale) {
    if (locale.languageCode == 'zh') {
      final traditional =
          locale.scriptCode == 'Hant' ||
          const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
      return traditional ? 'zh_Hant' : 'zh';
    }
    return supportedLanguages.contains(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }

  /// The app language for the system's preferred [locales], in order: the
  /// first one the app has; else English (not Flutter's default, the first
  /// language it was built with).
  static String languageForList(List<Locale>? locales) {
    for (final locale in locales ?? const <Locale>[]) {
      if (locale.languageCode == 'zh' ||
          supportedLanguages.contains(locale.languageCode)) {
        return languageFor(locale);
      }
    }
    return 'en';
  }

  /// The core's routing regions (`routing.region`); empty is none.
  static const regions = ['ir', 'cn', 'ru', 'af', 'tr', 'id', 'br', ''];

  Locale? get locale => language.isEmpty ? null : localeOf(language);

  /// The routing region most users of [language] want: Persian is Iran,
  /// Chinese China, Russian Russia; null when a language says nothing.
  static String? regionForLanguage(String language) => switch (language) {
    'fa' => 'ir',
    'zh' => 'cn',
    'ru' => 'ru',
    'id' => 'id',
    'tr' => 'tr',
    'pt' => 'br',
    _ => null,
  };

  /// The region to offer first: from [language], else from the system's
  /// country ([countryCode], such as IR), else none.
  static String suggestedRegion(String language, String? countryCode) {
    final byLanguage = regionForLanguage(language);
    if (byLanguage != null) return byLanguage;
    final country = (countryCode ?? '').toLowerCase();
    return regions.contains(country) ? country : '';
  }

  static Future<AppSettings> load(String dataDir) async {
    final s = AppSettings(
      file: File('$dataDir${Platform.pathSeparator}app-settings.json'),
    );
    try {
      final j = jsonDecode(await s.file!.readAsString());
      if (j is Map<String, Object?>) {
        if (j['language'] case final String l
            when supportedLanguages.contains(l)) {
          s.language = l;
        }
        s.themeMode =
            ThemeMode.values.asNameMap()[j['theme']] ?? ThemeMode.system;
        s.closeAction =
            CloseAction.values.asNameMap()[j['close']] ?? CloseAction.ask;
        s.firstRun = j['welcome_done'] != true;
        s.showPublicIp = j['show_public_ip'] == true;
        if (j['dismissed_update'] case final String v) s.dismissedUpdate = v;
        if (j['update_version'] case final String v) s.updateVersion = v;
        if (j['update_url'] case final String v) s.updateUrl = v;
        s.updateCheckedAt = switch (j['update_checked_at']) {
          final String t => DateTime.tryParse(t),
          _ => null,
        };
        s.lowQuotaDismissedAt = switch (j['low_quota_dismissed_at']) {
          final String t => DateTime.tryParse(t),
          _ => null,
        };
        s.autostart = j['autostart'] != false;
        s.autoConnect = j['auto_connect'] == true;
        s.autoUpdate = j['auto_update'] != false;
        s.udpNotice = j['udp_notice'] != false;
        if (j['hidden_connection_columns'] case final List<Object?> v) {
          s.hiddenConnectionColumns = {...v.whereType<String>()};
        }
        if (j['ember_mode'] case final int v) s.emberMode = v;
        s.ember2DefaultsApplied = j['ember2_defaults'] == true;
        s.desktopDefaultsApplied = j['ember_desktop_defaults'] == true;
        if (j['ember_en_default'] == true) {
          s.emberEnDefaultApplied = true;
        } else {
          // One-time 2006 migration: English is the default language.
          // Builds up to 2005 shipped 'fa' as the baked-in default, so
          // a stored 'fa' was the default, not a choice; reset it once
          // and persist, after which the picker owns the value.
          s.language = 'en';
          s.emberEnDefaultApplied = true;
          await s._save();
        }
      }
    } on FileSystemException {
      // First run: defaults, and the welcome page.
      s.firstRun = true;
      s.emberEnDefaultApplied = true;
    } on FormatException {
      // A broken file: defaults, rewritten on the next change.
      s.emberEnDefaultApplied = true;
    }
    return s;
  }

  void update({
    String? language,
    ThemeMode? themeMode,
    CloseAction? closeAction,
    bool? firstRun,
    bool? showPublicIp,
    DateTime? lowQuotaDismissedAt,
    String? dismissedUpdate,
    DateTime? updateCheckedAt,
    String? updateVersion,
    String? updateUrl,
    bool? autostart,
    bool? autoConnect,
    bool? autoUpdate,
    bool? udpNotice,
    Set<String>? hiddenConnectionColumns,
    int? emberMode,
    bool? ember2DefaultsApplied,
    bool? emberEnDefaultApplied,
    bool? desktopDefaultsApplied,
  }) {
    this.emberMode = emberMode ?? this.emberMode;
    this.emberEnDefaultApplied =
        emberEnDefaultApplied ?? this.emberEnDefaultApplied;
    this.ember2DefaultsApplied =
        ember2DefaultsApplied ?? this.ember2DefaultsApplied;
    this.desktopDefaultsApplied =
        desktopDefaultsApplied ?? this.desktopDefaultsApplied;
    this.hiddenConnectionColumns =
        hiddenConnectionColumns ?? this.hiddenConnectionColumns;
    this.udpNotice = udpNotice ?? this.udpNotice;
    this.autoUpdate = autoUpdate ?? this.autoUpdate;
    this.autostart = autostart ?? this.autostart;
    this.autoConnect = autoConnect ?? this.autoConnect;
    this.showPublicIp = showPublicIp ?? this.showPublicIp;
    this.lowQuotaDismissedAt = lowQuotaDismissedAt ?? this.lowQuotaDismissedAt;
    this.dismissedUpdate = dismissedUpdate ?? this.dismissedUpdate;
    this.updateCheckedAt = updateCheckedAt ?? this.updateCheckedAt;
    this.updateVersion = updateVersion ?? this.updateVersion;
    this.updateUrl = updateUrl ?? this.updateUrl;
    this.firstRun = firstRun ?? this.firstRun;
    this.language = language ?? this.language;
    this.themeMode = themeMode ?? this.themeMode;
    this.closeAction = closeAction ?? this.closeAction;
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'language': language,
          'theme': themeMode.name,
          'close': closeAction.name,
          'welcome_done': !firstRun,
          'show_public_ip': showPublicIp,
          'low_quota_dismissed_at': lowQuotaDismissedAt?.toIso8601String(),
          'dismissed_update': dismissedUpdate,
          'update_checked_at': updateCheckedAt?.toIso8601String(),
          'update_version': updateVersion,
          'update_url': updateUrl,
          'autostart': autostart,
          'auto_connect': autoConnect,
          'auto_update': autoUpdate,
          'udp_notice': udpNotice,
          'hidden_connection_columns': hiddenConnectionColumns.toList(),
          'ember_mode': emberMode,
          'ember2_defaults': ember2DefaultsApplied,
          'ember_desktop_defaults': desktopDefaultsApplied,
          'ember_en_default': emberEnDefaultApplied,
        }),
      );
    } on FileSystemException {
      // Not fatal: the choice holds until the app quits.
    }
  }
}
